#!/usr/bin/env python3
"""Build, sign, stage, verify and promote a journaled RedditBox APT release."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from email.utils import format_datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import uuid

from package_variant import variant
from apt_repository import (MAX_METADATA, MAX_PACKAGE, generate_repository, inspect_package,
                            next_version, parse_fields, release_bytes, require, sha256,
                            signed_checksums, validate_manifest)

ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = re.compile(r"(?:[A-F0-9]{40}|[A-F0-9]{64})\Z")
PHASES = {"prepared", "building", "built", "indexed", "deployed", "verified", "promoting", "promoted", "production-verified", "complete"}
METADATA_NAMES = {"Packages", "Packages.gz", "Release", "InRelease", "Release.gpg", "repository.json", "public-key.asc", "redditbox-archive-keyring.gpg"}


@contextmanager
def local_publication_lock(directory):
    directory.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(directory / ".publisher.lock", os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    acquired = False
    try:
        if os.name == "nt":
            import msvcrt
            if os.fstat(descriptor).st_size == 0:
                os.write(descriptor, b"0")
            os.lseek(descriptor, 0, os.SEEK_SET)
            try:
                msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise ValueError("Another release process is using this checkout; never run simultaneous --resume commands") from error
        else:
            import fcntl
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise ValueError("Another release process is using this checkout; never run simultaneous --resume commands") from error
        acquired = True
        yield
    finally:
        if acquired and os.name == "nt":
            os.lseek(descriptor, 0, os.SEEK_SET)
            msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
        os.close(descriptor)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        if os.name != "nt":
            descriptor = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def repository_url(value, scheme="rootless"):
    expected = "/apt/" + variant(scheme)["repository"]
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment and not parsed.port
            and parsed.path.rstrip("/") == expected, "APT_REPOSITORY_URL must match the selected package variant: https://HOST" + expected + "/")
    return f"https://{parsed.hostname}{expected}/"


def deployment_url(output):
    candidates = re.findall(r"https://[a-z0-9-]+\.vercel\.app/?", output)
    require(len(set(candidates)) == 1, "Vercel did not return one unambiguous deployment URL; retain the journal")
    return candidates[-1].rstrip("/")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        return None


def fetch(url, maximum, *, bypass=None, redirect=None):
    """Only the explicitly expected package redirect is permitted; never forward headers."""
    headers = {"Cache-Control": "no-cache", "User-Agent": "RedditBox-Release/1"}
    if bypass:
        headers["x-vercel-protection-bypass"] = bypass
    opener = urllib.request.build_opener(NoRedirect)
    try:
        response = opener.open(urllib.request.Request(url, headers=headers), timeout=60)
    except urllib.error.HTTPError as error:
        if redirect and error.code in (301, 302, 303, 307, 308) and error.headers.get("Location") == redirect:
            return fetch(redirect, maximum)
        raise
    with response:
        require(response.status == 200, "Repository request did not return HTTP 200")
        data = response.read(maximum + 1)
        require(0 < len(data) <= maximum, "Repository response exceeds its size limit or is empty")
        return data


def command(arguments, *, cwd=ROOT, env=None, timeout=120, visible=False):
    # Never print subprocess arguments: the Vercel token is passed only to its CLI.
    result = subprocess.run(arguments, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=None if visible else subprocess.PIPE,
                            stderr=None if visible else subprocess.PIPE,
                            timeout=timeout, check=False)
    if result.returncode and not visible:
        diagnostic = (result.stderr or b"").decode("utf-8", errors="replace")
        for name, value in (env or os.environ).items():
            if value and any(word in name.upper() for word in ("TOKEN", "SECRET", "PASSWORD", "PRIVATE_KEY")):
                diagnostic = diagnostic.replace(value, "[REDACTED]")
        print(diagnostic[-12000:], file=sys.stderr, flush=True)
    require(result.returncode == 0, f"{Path(arguments[0]).name} operation failed (exit {result.returncode}); release journal and lock retained")
    return "" if visible else result.stdout.decode("utf-8", errors="strict")


def verified_signature(status, fingerprint):
    rows = [line.split() for line in status.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
    require(len(rows) == 1 and len(rows[0]) >= 11, "Expected one valid repository signature")
    row = rows[0]
    primary = row[11] if len(row) > 11 else row[2]
    require(primary == fingerprint and row[9] in {"8", "9", "10"}, "Repository signature does not match the pinned GPG primary fingerprint and SHA-2 policy")


def validate_journal(journal, configuration, directory):
    require(isinstance(journal, dict) and type(journal.get("formatVersion")) is int and journal["formatVersion"] == 1
            and journal.get("configuration") == configuration and journal.get("phase") in PHASES, "Invalid release journal or changed publication configuration")
    require(str(uuid.UUID(journal.get("owner", ""))) == journal["owner"], "Invalid publication owner in journal")
    config = variant("rootful" if configuration["repositoryURL"].endswith("/redditbox-rootful/") else "rootless")
    phase = journal["phase"]
    if journal.get("requestedVersion") is not None:
        from apt_repository import version_tuple
        version_tuple(journal["requestedVersion"])
    if phase == "prepared":
        return
    from apt_repository import version_tuple
    version_tuple(journal.get("version"))
    previous = journal.get("previous")
    if previous is not None:
        validate_manifest(previous, configuration["blobHost"], config["architecture"])
    require(isinstance(journal.get("oldIndexes"), dict), "Missing authenticated previous index snapshot")
    for name, data in journal["oldIndexes"].items():
        require(re.fullmatch(r"by-hash/SHA256/[0-9a-f]{64}", name) and isinstance(data, str)
                and len(data) <= MAX_METADATA * 2, "Unsafe retained index in release journal")
        raw = bytes.fromhex(data)
        require(sha256(raw) == name.rsplit("/", 1)[1], "Corrupt retained index in release journal")
    if phase == "building":
        return
    expected_artifact = directory / f"com.redditbox_{journal['version']}_{config['architecture']}.deb"
    require(journal.get("artifact") == str(expected_artifact), "Release artifact escaped its journal directory")
    require(isinstance(journal.get("entry"), dict) and journal["entry"].get("version") == journal["version"], "Invalid saved package inspection")
    if phase == "built":
        return
    validate_manifest(journal.get("manifest"), configuration["blobHost"], config["architecture"])
    require(journal["manifest"]["version"] == journal["version"], "Journal version differs from repository")
    require(isinstance(journal.get("files"), dict) and METADATA_NAMES.issubset(journal["files"]), "Journal is missing signed metadata")
    for name, data in journal["files"].items():
        require(name in METADATA_NAMES or re.fullmatch(r"by-hash/SHA256/[0-9a-f]{64}", name), "Unsafe metadata path in journal")
        require(isinstance(data, str) and 0 < len(data) <= MAX_METADATA * 2, "Oversized signed metadata in journal")
        bytes.fromhex(data)
    require(json.loads(bytes.fromhex(journal["files"]["repository.json"])) == journal["manifest"], "Journal metadata disagrees with its manifest")
    if phase != "indexed":
        require(deployment_url(journal.get("deploymentURL", "")) == journal["deploymentURL"], "Invalid deployment URL in journal")


class Publisher:
    def __init__(self, root, environment):
        self.root, self.env = root, dict(environment)
        self.repo = repository_url(self.env.get("APT_REPOSITORY_URL", ""), self.env.get("RBX_PACKAGE_SCHEME", "rootless"))
        self.host = self.env.get("APT_BLOB_HOST", "")
        self.fingerprint = self.env.get("APT_SIGNING_KEY_FINGERPRINT", "").replace(" ", "").upper()
        require(FINGERPRINT.fullmatch(self.fingerprint), "Set the full APT_SIGNING_KEY_FINGERPRINT (separate from the license RSA key)")
        for variable in ("THEOS", "LICENSE_PUBLIC_KEY_FILE", "APT_BLOB_READ_WRITE_TOKEN", "VERCEL_TOKEN", "VERCEL_ORG_ID", "VERCEL_PROJECT_ID"):
            require(self.env.get(variable), "Missing required environment variable: " + variable)
        for tool in ("bash", "node", "gpg", "vercel", "xcodebuild", "xcodegen", "make", self.env.get("LDID", "ldid")):
            require(shutil.which(tool), "Missing required release tool: " + tool)
        self.directory = root / "build/release" / ("rootful" if self.scheme == "rootful" else "")
        self.journal_path = self.directory / "publish.json"
        self.config = {"repositoryURL": self.repo, "blobHost": self.host, "signingFingerprint": self.fingerprint,
                       "projectID": self.env["VERCEL_PROJECT_ID"], "organizationID": self.env["VERCEL_ORG_ID"]}
        self.journal = None

    @property
    def scheme(self):
        return "rootful" if self.repo.endswith("/redditbox-rootful/") else "rootless"

    @property
    def package(self):
        return variant(self.scheme)

    def save(self, **values):
        self.journal.update(values)
        atomic_json(self.journal_path, self.journal)

    def blob(self, action, **values):
        args = ["node", str(self.root / "cloud/scripts/apt-publish.mjs"), action]
        for key, value in values.items():
            args += ["--" + key, str(value)]
        return json.loads(command(args, cwd=self.root, env=self.env, timeout=600))

    def sign(self, files):
        directory = self.directory / "signed"
        directory.mkdir(parents=True, exist_ok=True)
        for name, data in files.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        base = ["gpg", "--batch", "--yes", "--pinentry-mode", "error", "--digest-algo", "SHA256", "--local-user", self.fingerprint]
        command(base + ["--armor", "--output", str(directory / "InRelease"), "--clearsign", str(directory / "Release")], env=self.env)
        command(base + ["--armor", "--output", str(directory / "Release.gpg"), "--detach-sign", str(directory / "Release")], env=self.env)
        for name, armor in (("public-key.asc", ["--armor"]), ("redditbox-archive-keyring.gpg", [])):
            command(["gpg", "--batch", "--yes", *armor, "--output", str(directory / name), "--export", self.fingerprint], env=self.env)
            require((directory / name).stat().st_size > 0, "APT public key export was empty")
        # Verify our own signature using the same pinned verifier used against production.
        require(self.verify_inrelease((directory / "InRelease").read_bytes()) == files["Release"], "Locally signed Release differs from requested bytes")
        files.update({name: (directory / name).read_bytes() for name in
                      ("InRelease", "Release.gpg", "public-key.asc", "redditbox-archive-keyring.gpg")})
        return files

    def verify_inrelease(self, data):
        with tempfile.TemporaryDirectory(prefix="verify-", dir=self.directory) as temporary:
            source, output = Path(temporary) / "InRelease", Path(temporary) / "Release"
            source.write_bytes(data)
            status = command(["gpg", "--batch", "--yes", "--status-fd", "1", "--output", str(output), "--decrypt", str(source)], env=self.env)
            verified_signature(status, self.fingerprint)
            return output.read_bytes()

    def published(self, base, *, bootstrap=False, bypass=None, packages=False):
        try:
            signature = fetch(base + "InRelease", MAX_METADATA, bypass=bypass)
        except urllib.error.HTTPError as error:
            if error.code != 404 or not bootstrap:
                raise
            # Only a fully absent repository may bootstrap; a partial deployment is a fault.
            for name in ("Release", "repository.json", "Packages"):
                try:
                    fetch(base + name, MAX_METADATA, bypass=bypass)
                except urllib.error.HTTPError as missing:
                    require(missing.code == 404, "Bootstrap repository returned an error other than 404")
                else:
                    raise ValueError("Partial repository already exists; bootstrap refused")
            return None, {}
        release = self.verify_inrelease(signature)
        architecture = variant("rootful" if base.endswith("/redditbox-rootful/") else "rootless")["architecture"]
        checksums = signed_checksums(release, architecture)
        files = {}
        for name, check in checksums.items():
            data = fetch(base + name, MAX_METADATA, bypass=bypass)
            require(len(data) == check["size"] and sha256(data) == check["sha256"], "Signed index checksum mismatch: " + name)
            files[name] = data
        manifest = validate_manifest(json.loads(files["repository.json"]), self.host, architecture)
        from apt_repository import packages_bytes, repository_entries
        require(files["Packages"] == packages_bytes(repository_entries(manifest)), "Signed package index differs from signed repository manifest")
        import gzip
        import io
        with gzip.GzipFile(fileobj=io.BytesIO(files["Packages.gz"])) as compressed:
            require(compressed.read(MAX_METADATA + 1) == files["Packages"], "Compressed package index differs from signed package index or exceeds its bound")
        indexes = {}
        for index in manifest.get("previousIndexes", []):
            data = fetch(base + index["path"], MAX_METADATA, bypass=bypass)
            require(len(data) == index["size"] and sha256(data) == index["sha256"], "Retained index digest mismatch")
            indexes[index["path"]] = data
        if packages:
            for entry in repository_entries(manifest):
                data = fetch(base + entry["filename"], min(entry["size"], MAX_PACKAGE), bypass=bypass, redirect=entry["blobURL"])
                require(len(data) == entry["size"] and sha256(data) == entry["sha256"], "Published package bytes differ from signed index: " + entry["version"])
        return manifest, indexes

    def check_peer(self, base=None, *, local=False, bypass=None):
        # Both repositories are included in one Vercel deployment. Never deploy
        # an outdated/missing companion index from a different checkout.
        base = base or self.repo
        origin = urlsplit(base)
        peer_scheme = "rootful" if self.scheme == "rootless" else "rootless"
        peer = variant(peer_scheme)
        url = f"{origin.scheme}://{origin.netloc}/apt/{peer['repository']}/"
        manifest, _ = self.published(url, bootstrap=True, bypass=bypass)
        if local:
            directory = self.root / "cloud/public/apt" / peer["repository"]
            if manifest is None:
                require(not directory.exists() or not any(directory.iterdir()), "Local companion repository would resurrect an unpublished index")
            else:
                require(directory.is_dir() and not directory.is_symlink(), "Fetch the current companion repository metadata commit before releasing")
                def read(name):
                    path = directory / name
                    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_METADATA, "Companion metadata is missing or unsafe: " + name)
                    return path.read_bytes()
                release = self.verify_inrelease(read("InRelease"))
                checksums = signed_checksums(release, peer["architecture"])
                require(read("Release") == release, "Companion Release differs from its signature")
                for name, expected in checksums.items():
                    data = read(name)
                    require(len(data) == expected["size"] and sha256(data) == expected["sha256"], "Companion index checksum mismatch")
                require(json.loads(read("repository.json")) == manifest, "Local companion repository is stale; fetch its current metadata commit")
                for index in manifest.get("previousIndexes", []):
                    data = read(index["path"])
                    require(len(data) == index["size"] and sha256(data) == index["sha256"], "Companion by-hash index is missing or corrupt")
                for name in METADATA_NAMES:
                    read(name)
                status = command(["gpg", "--batch", "--status-fd", "1", "--verify", str(directory / "Release.gpg"), str(directory / "Release")], env=self.env)
                verified_signature(status, self.fingerprint)
        return manifest

    def verify_target(self, base, bypass=None):
        manifest, _ = self.published(base, bypass=bypass, packages=True)
        require(manifest == self.journal["manifest"], "Deployed repository is not the exact journaled release")
        require(self.check_peer(base, bypass=bypass) == self.journal.get("peer"), "Deployment changed the companion repository")

    def materialize(self, files):
        target = self.root / "cloud/public/apt" / self.package["repository"]
        require(not target.is_symlink(), "APT metadata directory must not be a symlink")
        target.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=".redditbox-", dir=target.parent))
        for name, data in files.items():
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        # The directory is deployed as one Vercel snapshot, never written into the live site.
        backup = self.directory / ("metadata-before-" + uuid.uuid4().hex)
        if target.exists():
            os.replace(target, backup)
        try:
            os.replace(staging, target)
        except Exception:
            if backup.exists() and not target.exists():
                os.replace(backup, target)
            raise

    def run(self, requested=None, resume=False):
        with local_publication_lock(self.root / "build/release"):
            return self._run(requested, resume)

    def _run(self, requested=None, resume=False):
        if requested is not None:
            from apt_repository import version_tuple
            version_tuple(requested)
        self.directory.mkdir(parents=True, exist_ok=True)
        if self.journal_path.exists():
            require(self.journal_path.stat().st_size <= 256 * 1024 * 1024, "Release journal exceeds its size bound")
            previous_journal = json.loads(self.journal_path.read_text(encoding="utf-8"))
            validate_journal(previous_journal, self.config, self.directory)
            if previous_journal.get("phase") != "complete":
                require(resume, "An unfinished release exists; run scripts/release.sh --resume (never remove its lock)")
                if previous_journal["phase"] == "prepared":
                    require("requestedVersion" in previous_journal or requested is not None,
                            "Prepared legacy journal needs an explicit version: --resume X.Y.Z")
                    require(previous_journal.get("requestedVersion") in (None, requested) or requested is None,
                            "Resume must use the journaled requested version")
                else:
                    require(not requested or requested == previous_journal.get("version"), "Resume must use the journaled version")
                self.journal = previous_journal
            else:
                require(not resume, "The previous release is already complete")
                os.replace(self.journal_path, self.directory / ("published-" + previous_journal["version"] + ".json"))
        else:
            require(not resume, "No interrupted release journal exists")
        if self.journal is None:
            self.journal = {"formatVersion": 1, "configuration": self.config, "owner": str(uuid.uuid4()), "phase": "prepared", "requestedVersion": requested}
            self.save()
        if self.journal["phase"] == "prepared":
            if requested is not None:
                self.save(requestedVersion=requested)
            requested = self.journal.get("requestedVersion")
        lock = self.blob("lock", owner=self.journal["owner"])
        self.save(etag=lock["etag"])
        if self.journal["phase"] == "prepared":
            previous, indexes = self.published(self.repo, bootstrap=self.env.get("APT_BOOTSTRAP") == "1")
            current = parse_fields((self.root / "control").read_text())["Version"]
            chosen = next_version(current, (previous or {}).get("version"), requested)
            self.save(phase="building", version=chosen, previous=previous,
                      oldIndexes={name: data.hex() for name, data in indexes.items()})
        version = self.journal["version"]
        if self.journal["phase"] == "building":
            environment = dict(self.env, RBX_RELEASE_VERSION=version, RBX_PACKAGE_SCHEME=self.scheme)
            previous_hash = (self.journal["previous"] or {}).get("signingContractHash")
            if previous_hash:
                environment["RBX_PREVIOUS_SIGNING_CONTRACT_HASH"] = previous_hash
            else:
                environment.pop("RBX_PREVIOUS_SIGNING_CONTRACT_HASH", None)
            before = {str(path): (path.stat().st_mtime_ns, path.stat().st_size) for path in (self.root / "packages").glob("*.deb")}
            print("Building RedditBox " + version, flush=True)
            command(["bash", str(self.root / "scripts/build-mac.sh")], cwd=self.root, env=environment, timeout=7200, visible=True)
            candidates = [path for path in (self.root / "packages").glob("*.deb")
                          if before.get(str(path)) != (path.stat().st_mtime_ns, path.stat().st_size)]
            require(len(candidates) == 1, "Build must produce exactly one new or replaced Debian package")
            entry = inspect_package(candidates[0], version, self.root / "layout/DEBIAN", self.scheme)
            artifact = self.directory / Path(entry["filename"]).name
            shutil.copyfile(candidates[0], artifact)
            self.save(phase="built", artifact=str(artifact), entry=entry)
        if self.journal["phase"] == "built":
            print("Inspecting and uploading immutable package bytes", flush=True)
            entry = self.journal["entry"]
            actual = inspect_package(self.journal["artifact"], version, self.root / "layout/DEBIAN", self.scheme)
            require(actual == entry, "Saved package changed after inspection")
            blob = self.blob("upload", owner=self.journal["owner"], etag=self.journal["etag"], file=self.journal["artifact"],
                             pathname="apt/" + self.package["repository"] + "/debs/" + entry["sha256"] + "/" + Path(entry["filename"]).name)
            require(blob["sha256"] == entry["sha256"] and blob["size"] == entry["size"], "Blob upload receipt does not match inspected package")
            entry = dict(entry, blobURL=blob["url"])
            now = datetime.now(timezone.utc)
            manifest, files = generate_repository(entry, self.journal["previous"], self.host, now.isoformat(),
                                                  {name: bytes.fromhex(data) for name, data in self.journal["oldIndexes"].items()})
            files["Release"] = release_bytes(files, format_datetime(now, usegmt=True), self.package["architecture"])
            files = self.sign(files)
            self.save(phase="indexed", manifest=manifest, files={name: data.hex() for name, data in files.items()})
        if self.journal["phase"] == "indexed":
            peer = self.check_peer(local=True)
            if "peer" in self.journal: require(peer == self.journal["peer"], "Companion repository changed during interrupted release")
            self.save(peer=peer)
            print("Deploying signed APT metadata without moving the production domain", flush=True)
            self.materialize({name: bytes.fromhex(data) for name, data in self.journal["files"].items()})
            output = command(["vercel", "deploy", "--prod", "--skip-domain", "--yes", "--token", self.env["VERCEL_TOKEN"]],
                             cwd=self.root, env=self.env, timeout=1800)
            self.save(phase="deployed", deploymentURL=deployment_url(output))
        if self.journal["phase"] == "deployed":
            print("Verifying staged signatures, indexes and all retained package downloads", flush=True)
            self.verify_target(self.journal["deploymentURL"] + "/apt/" + self.package["repository"] + "/", self.env.get("VERCEL_AUTOMATION_BYPASS_SECRET"))
            self.save(phase="verified")
        if self.journal["phase"] in {"verified", "promoting"}:
            require(self.check_peer() == self.journal.get("peer"), "Companion repository changed before promotion")
            previous, _ = self.published(self.repo, bootstrap=self.journal["previous"] is None)
            if previous == self.journal["manifest"]:
                self.save(phase="promoted")
            else:
                require(previous == self.journal["previous"], "Production changed outside this publisher; refusing to overwrite it")
                self.blob("check", owner=self.journal["owner"], etag=self.journal["etag"])
                self.save(phase="promoting")
                print("Promoting verified deployment", flush=True)
                command(["vercel", "promote", self.journal["deploymentURL"], "--yes", "--token", self.env["VERCEL_TOKEN"]],
                        cwd=self.root / "cloud", env=self.env, timeout=600)
                self.save(phase="promoted")
        if self.journal["phase"] == "promoted":
            self.verify_target(self.repo)
            self.save(phase="production-verified")
        if self.journal["phase"] == "production-verified":
            # Recheck on resume before unlocking, including a lost prior unlock acknowledgement.
            self.verify_target(self.repo)
            self.blob("unlock", owner=self.journal["owner"], etag=self.journal["etag"])
            self.save(phase="complete")
        print("Published " + version + ": " + self.repo)
        print("APT signing fingerprint: " + self.fingerprint)
        if self.journal["manifest"]["requiresMDMReadoption"]:
            print("MDM RE-ADOPTION REQUIRED: validate per-app VPN association for every existing clone before opening traffic.")
        print("Preserve these exact signed indexes before any later cloud deployment:")
        print("  git add cloud/public/apt/" + self.package["repository"])
        print('  git commit -m "Publish APT repository ' + version + '"')
        print("  git push origin HEAD")
        print("Keep production Git auto-deploy disabled until that metadata commit is present on its deployment branch.")
        print("On-device acceptance (record PASS/FAIL and evidence; these are not completed checks):")
        print("  1. Refresh the trusted Sileo/APT source, install/upgrade, verify version " + version + ".")
        print("  2. Verify license status, Diagnostics version and all five saved profile IDs/count after upgrade.")
        print("  3. Verify each clone's managed per-app VPN association; keep traffic CLOSED until proven.")
        print("  4. Create a profile; replace an inactive profile and verify new identity plus preserved name/role.")
        print("  5. Capture the A/B switch: old clone stopped, no direct traffic, correct proxy exit, then login.")
        print("  6. If browser login fails, retain callback/provider logs; follow docs/on-device-smoke-checklist.md.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", nargs="?", help="X.Y.Z; omitted means the next version after local/published versions")
    parser.add_argument("--resume", action="store_true", help="Resume the durable local release journal using the same lock owner")
    args = parser.parse_args()
    try:
        require(sys.platform == "darwin", "Release builds require macOS with Xcode and Theos")
        Publisher(ROOT, os.environ).run(args.version, args.resume)
    except (ValueError, OSError, subprocess.SubprocessError, urllib.error.URLError, json.JSONDecodeError) as error:
        # Network/SDK exception representations may include credential-bearing request context.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__ + ": release operation failed"
        print(message, file=sys.stderr)
        print("No automatic rollback/unlock was attempted. Keep the selected variant's build/release journal and use the same RBX_PACKAGE_SCHEME with --resume after fixing the cause.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
