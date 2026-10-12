#!/usr/bin/env python3
"""Verify a private runtime backup and inventory recovered container metadata.

Read-only engineering tool. Does not extract archives, transform identities,
read a phone, import keys, migrate data, or authorize package installation.
Output is aggregate evidence; user values never appear in reports/errors.
"""
import argparse
from collections import Counter
from contextlib import contextmanager
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
import tarfile
from xml.parsers.expat import ExpatError
import zlib

ROOTS = ("var/mobile/Library/SocialBox/Containers",
         "var/jb/var/mobile/Library/SocialBox/Containers")
# Classification only: these names do not enable app admission in the registry.
APPS = {"com.reddit.Reddit": "reddit", "com.facebook.Facebook": "facebook",
        "com.burbn.instagram": "instagram", "com.atebits.Tweetie2": "twitter"}
MAX_METADATA = 8 * 1024 * 1024
MAX_MANIFEST = 64 * 1024 * 1024
MAX_ARCHIVE = 1024 * 1024 * 1024
MAX_EXPANDED = 2 * 1024 * 1024 * 1024
BUNDLE = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\Z")


class InventoryError(ValueError):
    """A fixed reference code, never an input-derived message."""


def require(condition, code):
    if not condition: raise InventoryError(code)


def integer(value, minimum=0):
    return type(value) is int and minimum <= value <= 2**63 - 1


def canonical_path(value):
    require(isinstance(value, str) and 0 < len(value) <= 4096, "ARCHIVE_PATH_INVALID")
    if value.startswith("./"): value = value[2:]
    require(not value.startswith("/") and not any(ord(c) < 32 or ord(c) == 127 for c in value),
            "ARCHIVE_PATH_INVALID")
    require(all(part not in ("", ".", "..") for part in value.split("/")), "ARCHIVE_PATH_INVALID")
    return value


@contextmanager
def regular_input(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum, "INPUT_SIZE_OR_TYPE_INVALID")
        yield stream
        after = os.fstat(stream.fileno())
        signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(signature(before) == signature(after), "INPUT_CHANGED_DURING_INSPECTION")


class BoundedReader:
    def __init__(self, stream, maximum): self.stream, self.remaining = stream, maximum
    def read(self, size):
        require(0 <= size <= self.remaining, "ARCHIVE_EXPANSION_LIMIT")
        data = self.stream.read(size)
        self.remaining -= len(data)
        return data


def sha_stream(stream):
    digest = hashlib.sha256()
    while chunk := stream.read(1024 * 1024): digest.update(chunk)
    return digest.hexdigest()


def metadata_target(name):
    for root in ROOTS:
        if name == root + "/global_metadata.plist": return root, None
        prefix = root + "/"
        if name.startswith(prefix):
            parts = name[len(prefix):].split("/")
            if len(parts) == 2 and parts[1] == "metadata.plist":
                require(BUNDLE.fullmatch(parts[0]), "APP_INDEX_PATH_INVALID")
                return root, parts[0]
    return None


def read_verified_metadata(archive_path, manifest_path, max_entries, max_bytes):
    with regular_input(manifest_path, MAX_MANIFEST) as source:
        manifest_raw = source.read()
    manifest = json.loads(manifest_raw)
    require(isinstance(manifest, dict) and type(manifest.get("schemaVersion")) is int and
            manifest["schemaVersion"] == 1, "MANIFEST_SCHEMA_UNSUPPORTED")
    entries = manifest.get("entries")
    require(isinstance(entries, list) and 0 < len(entries) <= max_entries, "MANIFEST_ENTRY_LIMIT")
    expected = {}
    for item in entries:
        require(isinstance(item, dict), "MANIFEST_ENTRY_INVALID")
        name = canonical_path(item.get("path"))
        require(name not in expected, "MANIFEST_DUPLICATE_PATH")
        expected[name] = {**item, "path": name}
    documents = {}; seen = set(); total = metadata_bytes = 0
    with regular_input(archive_path, MAX_ARCHIVE) as source:
        archive_digest = sha_stream(source); source.seek(0)
        # Use an explicitly bounded decompressed reader, including hidden PAX
        # headers. tarfile alone does not bound headers before yielding members.
        with gzip.GzipFile(fileobj=source, mode="rb") as compressed:
            reader = BoundedReader(compressed, max_bytes)
            with tarfile.open(fileobj=reader, mode="r|") as archive:
                for member in archive:
                    require(len(seen) < max_entries, "ARCHIVE_ENTRY_LIMIT")
                    name = canonical_path(member.name)
                    require(name not in seen, "ARCHIVE_DUPLICATE_PATH")
                    require(name in expected, "MANIFEST_MEMBER_MISSING")
                    require(member.isfile() or member.isdir() or member.issym() or member.islnk(),
                            "ARCHIVE_MEMBER_TYPE_UNSUPPORTED")
                    seen.add(name); total += member.size
                    require(0 <= member.size <= max_bytes and total <= max_bytes, "ARCHIVE_PAYLOAD_LIMIT")
                    actual = {"path": name, "type": member.type.decode("ascii"), "mode": member.mode,
                              "uid": member.uid, "gid": member.gid, "size": member.size,
                              "mtime": member.mtime, "link": member.linkname,
                              "pax": {k: v for k, v in member.pax_headers.items() if k not in ("atime", "ctime")}}
                    target = metadata_target(name)
                    if target:
                        metadata_bytes += member.size
                        require(member.isfile() and member.size <= MAX_METADATA and
                                metadata_bytes <= MAX_MANIFEST and len(documents) < 512,
                                "METADATA_SIZE_OR_TYPE_INVALID")
                    raw = bytearray() if target else None
                    if member.isfile():
                        digest = hashlib.sha256(); stream = archive.extractfile(member)
                        remaining = member.size
                        while remaining:
                            chunk = stream.read(min(remaining, 1024 * 1024))
                            require(chunk, "ARCHIVE_TRUNCATED")
                            remaining -= len(chunk); digest.update(chunk)
                            if raw is not None: raw.extend(chunk)
                        actual["sha256"] = digest.hexdigest()
                    require(actual == expected[name], "MANIFEST_RECORD_MISMATCH")
                    if target:
                        require(target not in documents, "METADATA_DUPLICATE")
                        documents[target] = plistlib.loads(raw)
            # Check the gzip checksum/trailer too, rather than stopping at tar's
            # end markers. Expansion remains bounded for trailing compressed data.
            require(reader.remaining > 0, "ARCHIVE_EXPANSION_LIMIT")
            while reader.read(min(1024 * 1024, reader.remaining)):
                require(reader.remaining > 0, "ARCHIVE_EXPANSION_LIMIT")
        source.seek(0)
        require(sha_stream(source) == archive_digest, "INPUT_CHANGED_DURING_INSPECTION")
    require(seen == set(expected), "ARCHIVE_MEMBER_MISSING")
    preference_roots = ("var/mobile/Library/Preferences/", "var/jb/var/mobile/Library/Preferences/")
    source_profiles = sum(any(name.startswith(root + "com.redditbox.profiles/") and
                              name.endswith(".json") for root in preference_roots) for name in seen)
    source_stores = sum(name in {root + "com.redditbox.store.json" for root in preference_roots} for name in seen)
    return documents, {"archiveSHA256": archive_digest,
                       "manifestSHA256": hashlib.sha256(manifest_raw).hexdigest(),
                       "archiveEntries": len(seen), "archivePayloadBytes": total,
                       "existingSourceProfileEntries": source_profiles,
                       "existingSourceStoreEntries": source_stores}


def records(document, issues):
    require(isinstance(document, dict), "METADATA_DOCUMENT_INVALID")
    rows = document.get("containers")
    require(isinstance(rows, list) and len(rows) <= 10000, "CONTAINER_ARRAY_INVALID")
    result = {}
    for row in rows:
        require(isinstance(row, dict) and integer(row.get("id"), 1), "CONTAINER_RECORD_INVALID")
        ident = row["id"]
        require(ident not in result, "CONTAINER_ID_DUPLICATE")
        require(isinstance(row.get("name"), str) and len(row["name"]) <= 4096, "CONTAINER_NAME_INVALID")
        apps = row.get("apps")
        require(isinstance(apps, list) and len(apps) <= 256 and
                all(isinstance(a, str) and len(a) <= 255 and BUNDLE.fullmatch(a) for a in apps), "APP_MEMBERSHIP_INVALID")
        require(len(set(apps)) == len(apps), "APP_MEMBERSHIP_DUPLICATE")
        require(isinstance(row.get("spoofProfile"), str) and 0 < len(row["spoofProfile"]) <= 4096,
                "IDENTITY_REFERENCE_INVALID")
        if set(row) - {"id", "name", "apps", "created", "gpsEnabled", "spoofProfile"}:
            issues["UNREVIEWED_RECORD_FIELDS"] += 1
        result[ident] = row
    require(integer(document.get("activeContainer")), "ACTIVE_ID_INVALID")
    require(document["activeContainer"] in result or document["activeContainer"] == 0, "ACTIVE_ID_UNRESOLVED")
    return result


def inventory(documents, evidence):
    issues = Counter(); known = Counter({name: 0 for name in APPS.values()})
    roots = [root for root in ROOTS if (root, None) in documents]
    require(roots, "GLOBAL_METADATA_MISSING")
    total = indexed = unknown = unique_references = 0
    consistent = True
    if len(roots) > 1: issues["MULTIPLE_NAMESPACES_REQUIRE_RECONCILIATION"] += 1
    for root in roots:
        global_doc = documents[root, None]
        require(isinstance(global_doc, dict) and type(global_doc.get("version")) is int and
                global_doc["version"] == 2, "GLOBAL_VERSION_UNSUPPORTED")
        rows = records(global_doc, issues); total += len(rows)
        require(integer(global_doc.get("nextContainerID"), 1) and
                global_doc["nextContainerID"] > max(rows, default=0), "NEXT_ID_INVALID")
        require(isinstance(global_doc.get("defaultSeed"), str) and 0 < len(global_doc["defaultSeed"]) <= 4096,
                "DEFAULT_IDENTITY_INVALID")
        if set(global_doc) - {"activeContainer", "containers", "defaultSeed", "nextContainerID", "version"}:
            issues["UNREVIEWED_GLOBAL_FIELDS"] += 1
        references = {row["spoofProfile"] for row in rows.values()}; unique_references += len(references)
        if len(references) != len(rows): issues["SHARED_IDENTITY_REFERENCE_REQUIRES_REVIEW"] += 1
        memberships = {}
        for ident, row in rows.items():
            for app in row["apps"]:
                memberships.setdefault(app, set()).add(ident)
                if app in APPS: known[APPS[app]] += 1
                else: unknown += 1
        local_indexes = {app: doc for (namespace, app), doc in documents.items() if namespace == root and app}
        for app in set(memberships) | set(local_indexes):
            if app not in local_indexes:
                issues["APP_INDEX_MISSING"] += 1; consistent = False; continue
            doc = local_indexes[app]
            app_rows = records(doc, issues); indexed += len(app_rows)
            if doc.get("bundleID") != app:
                issues["APP_INDEX_OWNER_MISMATCH"] += 1; consistent = False
            if set(doc) - {"activeContainer", "bundleID", "containers"}:
                issues["UNREVIEWED_APP_INDEX_FIELDS"] += 1
            if set(app_rows) != memberships.get(app, set()):
                issues["APP_INDEX_MEMBERSHIP_MISMATCH"] += 1; consistent = False
            for ident, row in app_rows.items():
                # Compare stable IDs and original values, not array position.
                if rows.get(ident) != row:
                    issues["APP_INDEX_RECORD_MISMATCH"] += 1; consistent = False
            if doc.get("activeContainer") != global_doc["activeContainer"]:
                issues["ACTIVE_SELECTIONS_REQUIRE_RECONCILIATION"] += 1
    for root, app in documents:
        if app and root not in roots:
            issues["APP_INDEX_WITHOUT_GLOBAL_NAMESPACE"] += 1; consistent = False
    if unknown: issues["UNSUPPORTED_APP_MEMBERSHIP"] += unknown
    if evidence["existingSourceProfileEntries"] or evidence["existingSourceStoreEntries"]:
        issues["EXISTING_SOURCE_STATE_REQUIRES_RECONCILIATION"] += 1
    return {"schemaVersion": 1, "operation": "read-only-source-transition-inventory",
            **evidence, "archiveVerifiedAgainstManifest": True,
            "metadataConsistent": consistent, "namespaceCount": len(roots),
            "containerRecords": total, "perAppIndexRecords": indexed,
            "knownAppMemberships": dict(known), "unknownAppMemberships": unknown,
            "distinctIdentityReferencesWithinNamespaces": unique_references,
            "issues": dict(sorted(issues.items())),
            "readyForInstallation": False, "freshDeviceSnapshot": False,
            "accountDataRecoveryProven": False, "globalKeychainRecoveryProven": False,
            "identityConversionProven": False, "deviceOrArchiveModified": False,
            "remainingGates": ["fresh-quiescent-device-backup", "existing-source-data-reconciliation",
                               "supported-app-data-mapping",
                               "identity-conversion-without-regeneration", "account-and-keychain-recovery",
                               "transactional-migration-and-rollback", "installed-source-runtime-acceptance"]}


def inspect_backup(archive, manifest, *, max_entries=50000, max_bytes=MAX_EXPANDED):
    try:
        docs, evidence = read_verified_metadata(archive, manifest, max_entries, max_bytes)
        return inventory(docs, evidence)
    except InventoryError: raise
    except (OSError, ValueError, TypeError, KeyError, RecursionError, EOFError,
            tarfile.TarError, plistlib.InvalidFileException, ExpatError, zlib.error):
        raise InventoryError("BACKUP_UNREADABLE_OR_MALFORMED") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = inspect_backup(args.archive, args.manifest)
    except InventoryError as error:
        print(json.dumps({"error": str(error), "readyForInstallation": False}))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["metadataConsistent"] else 2


if __name__ == "__main__": sys.exit(main())
