#!/usr/bin/env python3
"""AUDIT-001: compare labelled, locally observed Reddit request headers.

Start a new capture with an unused output path, for example:
    mitmproxy -s tools/leak_audit.py --set rbx_audit_output=work/audit-A-B.json \
        --set rbx_audit_container=A

Before using B, change the addon option rbx_audit_container to B in mitmproxy.
Labels are local observer input, never an HTTP header. Each request snapshots its
label before a later response can arrive. The operator must independently record
which installed clone/PID was active; a label is not proof of process identity.

Only HMAC fingerprints of the named header values are saved, with a fresh key
kept in memory for this run. Captures from different runs cannot be combined.
Legacy unlabelled/raw-value files are rejected, never treated as comparable.
NO_REUSE_OBSERVED describes the observed comparable headers only, not a leak-free
verdict, full traffic capture, payload inspection, or a device isolation proof.
"""

import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
import uuid

IDENTITY_HEADERS = (
    "client-vendor-id", "x-reddit-device-id", "x-reddit-loid",
    "x-reddit-session", "x-hmac-signed-result", "x-attestation",
    "x-attestation-assertion", "authorization",
)
SCHEME = "hmac-sha256-per-run-key"
META = "redditbox_audit_request_v2"
SCOPE = (
    "Labelled observer captures of listed request headers only; not a leak-free verdict. "
    "Missing fields, bodies, unobserved transports, and process attribution remain unverified. "
    "Shared server/account tokens may be intentional reuse and require context."
)


def reddit_host(host):
    value = (host or "").lower().rstrip(".")
    return any(value == domain or value.endswith("." + domain)
               for domain in ("reddit.com", "redditmedia.com", "redditstatic.com", "redd.it"))


def valid_label(label):
    return isinstance(label, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}", label) is not None


def validate_document(document):
    """Reject legacy/raw records and incompatible capture sessions explicitly."""
    if not isinstance(document, dict) or document.get("schema_version") != 2:
        raise ValueError("Incompatible audit capture: a labelled schema 2 capture is required")
    if document.get("fingerprint_scheme") != SCHEME or not re.fullmatch(r"[0-9a-f]{32}", str(document.get("run_id", ""))):
        raise ValueError("Incompatible fingerprint scheme or capture run")
    if set(document) != {"schema_version", "fingerprint_scheme", "run_id", "unlabelled_requests", "containers"}:
        raise ValueError("Unexpected audit fields; raw/legacy capture records are not accepted")
    count = document.get("unlabelled_requests")
    containers = document.get("containers")
    if type(count) is not int or count < 0 or not isinstance(containers, dict):
        raise ValueError("Invalid capture counts or container mapping")
    for label, record in containers.items():
        if not valid_label(label) or not isinstance(record, dict) or set(record) != {"requests", "headers"}:
            raise ValueError("Invalid container capture record")
        requests, headers = record["requests"], record["headers"]
        if type(requests) is not int or requests < 1 or not isinstance(headers, dict):
            raise ValueError("Invalid labelled request count")
        for name, values in headers.items():
            if name not in IDENTITY_HEADERS or not isinstance(values, dict) or not values:
                raise ValueError("Invalid captured header")
            for fingerprint, occurrences in values.items():
                if not re.fullmatch(r"[0-9a-f]{64}", fingerprint) or type(occurrences) is not int or not 0 < occurrences <= requests:
                    raise ValueError("Invalid header fingerprint or count")
    return document


class AuditRecorder:
    def __init__(self, key=None):
        self._key = key if key is not None else secrets.token_bytes(32)
        self._seen = set()
        self.document = {
            "schema_version": 2, "fingerprint_scheme": SCHEME,
            "run_id": uuid.uuid4().hex, "unlabelled_requests": 0, "containers": {},
        }

    def snapshot(self, host, headers, label):
        if not reddit_host(host):
            return None
        fingerprints = {}
        # mitmproxy Headers normally folds repeated fields. Compare every field
        # value so a common ID cannot disappear inside different folded lists.
        try:
            items = headers.items(multi=True)
        except TypeError:
            items = headers.items()  # Plain mappings in the pure test adapter.
        for name, value in items:
            name = name.lower()
            if name in IDENTITY_HEADERS and value:
                # Field name is domain separation. Raw auth/session values never
                # enter flow metadata or the persisted capture document.
                digest = hmac.new(self._key, (name + "\0" + value).encode(), hashlib.sha256).hexdigest()
                fingerprints.setdefault(name, set()).add(digest)
        return {"run_id": self.document["run_id"], "observation_id": uuid.uuid4().hex,
                "container": label if valid_label(label) else None,
                "headers": {name: sorted(values) for name, values in fingerprints.items()}}

    def record(self, snapshot):
        if snapshot is None:
            return
        if snapshot["run_id"] != self.document["run_id"]:
            raise ValueError("Cannot combine different capture runs")
        observation = snapshot["observation_id"]
        if observation in self._seen:
            return
        self._seen.add(observation)
        label = snapshot["container"]
        if not valid_label(label):
            self.document["unlabelled_requests"] += 1
            return
        record = self.document["containers"].setdefault(label, {"requests": 0, "headers": {}})
        record["requests"] += 1
        for name, fingerprints in snapshot["headers"].items():
            values = record["headers"].setdefault(name, {})
            for fingerprint in fingerprints:
                values[fingerprint] = values.get(fingerprint, 0) + 1


def analyze(document):
    validate_document(document)
    containers = document["containers"]
    reused, compared, unverified = {}, [], []
    for name in IDENTITY_HEADERS:
        owners = {}
        labels_with_field = []
        for label, record in containers.items():
            if name in record["headers"]:
                labels_with_field.append(label)
            for fingerprint in record["headers"].get(name, {}):
                owners.setdefault(fingerprint, []).append(label)
        shared = [{"fingerprint": value, "containers": sorted(labels)}
                  for value, labels in sorted(owners.items()) if len(labels) > 1]
        if shared:
            reused[name] = shared
        if len(containers) >= 2 and len(labels_with_field) == len(containers):
            compared.append(name)
        else:
            unverified.append(name)
    status = ("REUSE_DETECTED" if reused else
              "NO_REUSE_OBSERVED" if len(containers) >= 2 and compared and not document["unlabelled_requests"]
              else "NOT_VERIFIED")
    return {"status": status, "scope": SCOPE, "containers": sorted(containers),
            "coverage_status": "NOT_VERIFIED" if unverified or document["unlabelled_requests"]
            else "LISTED_HEADER_FIELDS_COMPARABLE_ONLY",
            "unlabelled_requests": document["unlabelled_requests"],
            "compared_fields": compared, "unverified_fields": unverified, "reused_fields": reused}


def save_audit(document, path):
    validate_document(document)
    path = Path(path)
    existed = path.exists()
    if existed:
        existing = validate_document(json.loads(path.read_text()))
        if existing["run_id"] != document["run_id"]:
            raise ValueError("Output belongs to another capture run; choose a new output path")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".redditbox-audit-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(document, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if existed:
            os.replace(temporary, path)
        else:
            # First publication must not overwrite another run racing to use
            # the same fresh filename.
            try:
                os.link(temporary, path)
            except FileExistsError as error:
                raise ValueError("Output was created concurrently; choose a new output path") from error
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class LeakAuditAddon:
    def __init__(self):
        self.recorder = AuditRecorder()
        self._output = None

    def options(self):
        # Import only in adapter; analyzer has no mitmproxy dependency.
        from mitmproxy import ctx
        return ctx.options

    def load(self, loader):
        loader.add_option("rbx_audit_container", str, "", "Local current-clone label (never sent as a header)")
        loader.add_option("rbx_audit_output", str, "work/leak-audit.json", "Fresh private output path for this capture run")

    def requestheaders(self, flow):
        # Bind before a streaming request body or later response. request()
        # must not relabel an earlier in-flight request after an option change.
        if META not in flow.metadata:
            flow.metadata[META] = self.recorder.snapshot(flow.request.host, flow.request.headers, self.options().rbx_audit_container)
            # Headers are already observed here, even if the request never gets
            # a response. This is observer evidence, not proof of wire delivery.
            self.recorder.record(flow.metadata[META])
            if flow.metadata[META] is not None:
                self.persist()

    def request(self, flow):
        self.requestheaders(flow)

    def response(self, flow):
        if META not in flow.metadata:
            # Addon attached mid-request: do not attribute it to current label.
            flow.metadata[META] = self.recorder.snapshot(flow.request.host, flow.request.headers, None)
        self.recorder.record(flow.metadata[META])
        if flow.metadata[META] is not None:
            self.persist()

    def error(self, flow):
        # A failed response can follow an outgoing identity-bearing request.
        self.response(flow)

    def persist(self):
        output = Path(self.options().rbx_audit_output).absolute()
        if self._output is not None and output != self._output:
            raise ValueError("Cannot change capture output mid-run; start a fresh addon session")
        save_audit(self.recorder.document, output)
        self._output = output

    def done(self):
        print(json.dumps(analyze(self.recorder.document), indent=2))


addons = [LeakAuditAddon()]
