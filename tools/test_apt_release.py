#!/usr/bin/env python3
"""Real Debian/GPG/index fixtures plus fault-injected calls through the release driver."""
import contextlib
import copy
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import apt_repository as apt
import release

HOST = "fixture-store.public.blob.vercel-storage.com"
FINGERPRINT = "A" * 40


def tar_bytes(files, special=None):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo("./" + name)
            member.size, member.mode = len(data), 0o755
            archive.addfile(member, io.BytesIO(data))
        if special:
            archive.addfile(special)
    return output.getvalue()


def ar_bytes(files):
    data = bytearray(b"!<arch>\n")
    for name, payload in files.items():
        header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n"
        data += header.encode() + payload + (b"\n" if len(payload) % 2 else b"")
    return bytes(data)


def package_fixture(path, version="1.2.3", *, additions=None, special=None, metadata=None, identity=None, scheme="rootless"):
    config = apt.variant(scheme)
    app_ids, _, payload_files = apt.payload_layout(config["architecture"])
    control = (ROOT / "control").read_text().replace("Version: 0.1.0", "Version: " + version)
    control = control.replace("Architecture: iphoneos-arm64", "Architecture: " + config["architecture"])
    controls = {"control": control.encode()}
    controls.update({name: apt.render_script((ROOT / "layout/DEBIAN" / name).read_text(encoding="utf-8"), scheme).encode() for name in ("postinst", "prerm", "postrm")})
    files = {name: b"fixture installed component\n" for name in payload_files}
    for name, identifier in app_ids.items():
        files[name] = plistlib.dumps({"CFBundleIdentifier": identity or identifier, "CFBundleVersion": version,
                                     "CFBundleShortVersionString": version})
    document = {"version": version, "schemaVersion": 2, "signingContractHash": "b" * 64, "requiresMDMReadoption": True}
    document.update(packageScheme=scheme, packageArchitecture=config["architecture"], installPrefix=config["prefix"])
    document.update(metadata or {})
    files[(config["prefix"] + "/usr/share/redditbox/release.json").lstrip("/")] = json.dumps(document).encode()
    files.update(additions or {})
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(ar_bytes({"debian-binary": b"2.0\n", "control.tar.gz": tar_bytes(controls), "data.tar.gz": tar_bytes(files, special)}))
    return path


def entry(version="1.2.3", scheme="rootless"):
    config = apt.variant(scheme)
    filename = f"debs/com.redditbox_{version}_{config['architecture']}.deb"
    return {"version": version, "filename": filename, "sha256": "c" * 64, "size": 5,
            "blobURL": f"https://{HOST}/apt/{config['repository']}/debs/" + "c" * 64 + "/" + Path(filename).name,
            "control": {"Package": "com.redditbox", "Architecture": config["architecture"], "Version": version, "Description": "Test"},
            "release": {"version": version, "schemaVersion": 2, "signingContractHash": "b" * 64, "requiresMDMReadoption": True}}


class PackageAndIndexes(unittest.TestCase):
    def test_dependencies_survive_the_next_redditbox_release(self):
        for scheme in ('rootless', 'rootful'):
            config = apt.variant(scheme)
            manifest, files = apt.generate_repository(entry(scheme=scheme), None, HOST, 'now')
            dependencies = []
            for package, version in [('ai.akemi.appinst', '2.1.1-redditbox1'), ('ai.akemi.appsyncunified', '116.0')]:
                filename = f"{package}_{version}_{config['architecture']}.deb"
                dependencies.append({'version': version, 'filename': 'debs/' + filename, 'sha256': 'd' * 64, 'size': 5,
                    'control': {'Package': package, 'Architecture': config['architecture'], 'Version': version},
                    'blobURL': f"https://{HOST}/apt/{config['repository']}/debs/" + 'd' * 64 + '/' + filename})
            amended, amended_files = apt.dependency_repository(manifest, dependencies, HOST, files)
            newer, newer_files = apt.generate_repository(entry('1.2.4', scheme), amended, HOST, 'later', amended_files)
            self.assertEqual(newer['dependencies'], dependencies)
            self.assertEqual(newer_files['Packages'], apt.packages_bytes(apt.repository_entries(newer)))
            self.assertEqual(amended['versions'], manifest['versions'])
            for change in ('architecture', 'url', 'duplicate'):
                bad = copy.deepcopy(dependencies)
                if change == 'architecture': bad[0]['control']['Architecture'] = 'all'
                if change == 'url': bad[0]['blobURL'] = 'https://evil.invalid/dependency.deb'
                if change == 'duplicate': bad[1] = bad[0]
                with self.assertRaises(ValueError): apt.dependency_repository(manifest, bad, HOST, files)

    def test_variants_reject_cross_install_payload_and_repository_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "package.deb"
            for scheme, other in (("rootless", "rootful"), ("rootful", "rootless")):
                with self.subTest(scheme=scheme):
                    config = apt.variant(scheme)
                    package_fixture(path, scheme=scheme)
                    apt.inspect_package(path, "1.2.3", ROOT / "layout/DEBIAN", scheme)
                    with self.assertRaises(ValueError):
                        apt.inspect_package(path, "1.2.3", scheme=other)
                    wrong_path = (apt.variant(other)["prefix"] + "/usr/bin/redditboxd").lstrip("/")
                    package_fixture(path, scheme=scheme, additions={wrong_path: b"wrong bootstrap"})
                    with self.assertRaises(ValueError):
                        apt.inspect_package(path, "1.2.3", scheme=scheme)
                    package_fixture(path, scheme=scheme, metadata={"packageScheme": other})
                    with self.assertRaises(ValueError):
                        apt.inspect_package(path, "1.2.3", scheme=scheme)
                    manifest, files = apt.generate_repository(entry(scheme=scheme), None, HOST, "now")
                    apt.validate_manifest(manifest, HOST, config["architecture"])
                    with self.assertRaises(ValueError):
                        apt.validate_manifest(manifest, HOST, apt.variant(other)["architecture"])
                    release_data = apt.release_bytes(files, "Wed, 09 Sep 2026 00:00:00 GMT", config["architecture"])
                    apt.signed_checksums(release_data, config["architecture"])
                    with self.assertRaises(ValueError):
                        apt.signed_checksums(release_data, apt.variant(other)["architecture"])
                    manifest["versions"][0]["blobURL"] = manifest["versions"][0]["blobURL"].replace(
                        "/apt/" + config["repository"] + "/", "/apt/" + apt.variant(other)["repository"] + "/")
                    with self.assertRaises(ValueError):
                        apt.validate_manifest(manifest, HOST, config["architecture"])

    def test_version_selection_and_component_bounds(self):
        self.assertEqual(apt.next_version("0.1.0"), "0.1.1")
        self.assertEqual(apt.next_version("0.1.0", "9.9999.9999"), "10.0.0")
        self.assertEqual(apt.next_version("0.1.0", "1.2.3", "2.0.0"), "2.0.0")
        for value in ("1.2", "01.2.3", "1.2.10000", "1.2.3-1", "1.2.3\n", "-1.0.0"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                apt.version_tuple(value)
        with self.assertRaises(ValueError):
            apt.next_version("0.1.0", "1.2.3", "1.2.3")
        with self.assertRaises(ValueError):
            apt.next_version("9999.9999.9999")

    def test_inspects_actual_debian_payload_and_retains_exact_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = package_fixture(Path(temporary) / "package.deb")
            result = apt.inspect_package(path, "1.2.3", ROOT / "layout/DEBIAN")
            self.assertEqual(result["sha256"], apt.sha256(path.read_bytes()))
            self.assertEqual(result["size"], path.stat().st_size)
            self.assertEqual(result["release"]["schemaVersion"], 2)
            with self.assertRaises(ValueError):
                apt.inspect_package(path, "1.2.4")

    def test_rejects_source_keys_userdata_traversal_links_and_wrong_identity(self):
        paths = ("var/mobile/Library/Preferences/com.redditbox.store.json", "../escape",
                 "var/jb/Applications/RedditBox.app/source.ipa", "var/jb/Applications/RedditBox.app/license-private.pem",
                 "var/jb/Applications/RedditBox.app/transaction.json")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "package.deb"
            for name in paths:
                with self.subTest(path=name), self.assertRaises(ValueError):
                    apt.inspect_package(package_fixture(path, additions={name: b"bad"}), "1.2.3")
            for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
                member = tarfile.TarInfo("var/jb/Applications/RedditBox.app/link")
                member.type, member.linkname = kind, "/var/mobile"
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    apt.inspect_package(package_fixture(path, special=member), "1.2.3")
            with self.assertRaises(ValueError):
                apt.inspect_package(package_fixture(path, identity="com.redditbox.profile.pfixture"), "1.2.3")
            for change in ({"schemaVersion": 3}, {"schemaVersion": True}, {"requiresMDMReadoption": 1}, {"signingContractHash": "bad"}):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    apt.inspect_package(package_fixture(path, metadata=change), "1.2.3")

    def test_three_versions_and_six_by_hash_indexes_survive_four_releases(self):
        previous, old = None, {}
        for version in ("1.0.0", "1.0.1", "1.0.2", "1.0.3"):
            previous, files = apt.generate_repository(entry(version), previous, HOST, "2026-09-09T00:00:00Z", old)
            old = {name: data for name, data in files.items() if name.startswith("by-hash/")}
            self.assertEqual(gzip.decompress(files["Packages.gz"]), files["Packages"])
            self.assertEqual(files["Packages.gz"], gzip.compress(files["Packages"], mtime=0))
            sums = apt.signed_checksums(apt.release_bytes(files, "Wed, 09 Sep 2026 00:00:00 GMT"))
            self.assertEqual(sums["repository.json"]["sha256"], apt.sha256(files["repository.json"]))
        self.assertEqual([item["version"] for item in previous["versions"]], ["1.0.3", "1.0.2", "1.0.1"])
        self.assertEqual(len(previous["previousIndexes"]), 6)
        with self.assertRaises(ValueError):
            apt.generate_repository(entry("1.0.4"), previous, HOST, "now", {})

    def test_manifest_allowlist_signed_field_injection_and_corrupt_hash(self):
        manifest, _ = apt.generate_repository(entry(), None, HOST, "now")
        for change in ({"blobHost": "evil.example"}, {"formatVersion": True}, {"requiresMDMReadoption": 1}, {"signingContractHash": None}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                apt.validate_manifest(dict(manifest, **change), HOST)
        broken = copy.deepcopy(manifest)
        broken["versions"][0]["blobURL"] += "?forward=evil"
        with self.assertRaises(ValueError):
            apt.validate_manifest(broken, HOST)
        broken = entry()
        broken["control"]["Description"] = "Okay\nFilename: attacker"
        with self.assertRaises(ValueError):
            apt.packages_bytes([broken])
        with self.assertRaises(ValueError):
            apt.archive_members(b"!<arch>\ntruncated")

    def test_local_publish_lock_excludes_concurrent_resume_and_releases(self):
        with tempfile.TemporaryDirectory() as temporary:
            with release.local_publication_lock(Path(temporary)):
                with self.assertRaises(ValueError), release.local_publication_lock(Path(temporary)):
                    self.fail("second publisher entered")
            with release.local_publication_lock(Path(temporary)):
                pass

    def test_download_redirect_drops_bypass_and_rejects_other_hosts(self):
        target = "https://" + HOST + "/apt/redditbox/debs/" + "a" * 64 + "/com.redditbox_1.2.3_iphoneos-arm64.deb"
        class Response(io.BytesIO):
            status = 200
        opener = mock.Mock()
        opener.open.side_effect = [urllib.error.HTTPError("fixture", 302, "redirect", {"Location": target}, None), Response(b"bytes")]
        with mock.patch.object(release.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(release.fetch("https://stage.vercel.app/apt/redditbox/debs/file.deb", 5, bypass="fixture-bypass", redirect=target), b"bytes")
        requests = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual(requests[0].get_header("X-vercel-protection-bypass"), "fixture-bypass")
        self.assertIsNone(requests[1].get_header("X-vercel-protection-bypass"))
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError("fixture", 302, "redirect", {"Location": "https://untrusted.example/"}, None)
        with mock.patch.object(release.urllib.request, "build_opener", return_value=opener), self.assertRaises(urllib.error.HTTPError):
            release.fetch("https://stage.vercel.app/apt/redditbox/debs/file.deb", 5, bypass="fixture-bypass", redirect=target)
        self.assertEqual(opener.open.call_count, 1)


class FakePublisher(release.Publisher):
    def __init__(self, root, state, scheme="rootless"):
        self.root, self.state = root, state
        self.repo, self.host, self.fingerprint = "https://fixture.example/apt/" + apt.variant(scheme)["repository"] + "/", HOST, FINGERPRINT
        self.env = {"VERCEL_TOKEN": "fixture-not-a-token", "APT_BOOTSTRAP": "1"}
        self.config = {"repositoryURL": self.repo, "blobHost": HOST, "signingFingerprint": FINGERPRINT,
                       "organizationID": "fixture", "projectID": "fixture"}
        self.directory = root / "build/release" / ("rootful" if scheme == "rootful" else "")
        self.journal_path, self.journal = self.directory / "publish.json", None

    def check_peer(self, base=None, *, local=False, bypass=None):
        self.fault("peer-check")
        return self.state.get("peer")

    def fault(self, action):
        if self.state.get("failure") == action:
            self.state["failure"] = None
            raise ValueError("Injected " + action + " failure")

    def blob(self, action, **values):
        if action == "lock":
            self.assert_owner(values["owner"])
            self.state["owner"] = values["owner"]
            self.fault("lock-ack")
            return {"etag": "fixture-etag"}
        self.assert_owner(values["owner"])
        if action == "check":
            self.fault("lock-check")
            return {"etag": "fixture-etag"}
        if action == "unlock":
            self.state["owner"] = None
            self.fault("unlock-ack")
            return {"ok": True}
        self.fault("upload")
        path = Path(values["file"])
        return {"url": "https://" + HOST + "/" + values["pathname"], "sha256": apt.sha256(path.read_bytes()), "size": path.stat().st_size}

    def assert_owner(self, owner):
        if self.state.get("owner") not in (None, owner):
            raise ValueError("Another publisher owns remote lock")

    def published(self, base, **kwargs):
        if base != self.repo:
            self.fault("stage-verify")
            return self.journal["manifest"], {}
        if kwargs.get("packages"):
            self.fault("production-verify")
        return self.state.get("production"), {}

    def sign(self, files):
        return dict(files, **{name: b"fixture signature or key" for name in
                             ("InRelease", "Release.gpg", "public-key.asc", "redditbox-archive-keyring.gpg")})


class DriverRecovery(unittest.TestCase):
    def test_release_fields_required_by_sileo_flat_repositories(self):
        # Sileo RepoManager rejects Release without Components, even for flat URLs.
        for architecture in ("iphoneos-arm64", "iphoneos-arm"):
            data = apt.release_bytes({"Packages": b"package", "Packages.gz": b"compressed", "repository.json": b"{}"}, "Wed, 09 Sep 2026 12:00:00 GMT", architecture)
            fields = apt.parse_fields(data.decode())
            self.assertEqual(fields["Components"], "main")
            self.assertEqual(fields["Architectures"], architecture)
            self.assertEqual(set(apt.signed_checksums(data, architecture)), {"Packages", "Packages.gz", "repository.json"})

    def test_failed_command_diagnostics_redact_credentials(self):
        output = io.StringIO()
        environment = dict(os.environ, VERCEL_TOKEN="fixture-private-token", AUTH_SECRET="fixture-auth-secret")
        code = "import os,sys; print('deployment failed: '+os.environ['VERCEL_TOKEN']+' '+os.environ['AUTH_SECRET'],file=sys.stderr);sys.exit(1)"
        with contextlib.redirect_stderr(output), self.assertRaisesRegex(ValueError, "journal and lock retained"):
            release.command([sys.executable, "-c", code], env=environment)
        self.assertIn("deployment failed:", output.getvalue())
        self.assertNotIn(environment["VERCEL_TOKEN"], output.getvalue())
        self.assertNotIn(environment["AUTH_SECRET"], output.getvalue())
        self.assertEqual(output.getvalue().count("[REDACTED]"), 2)

    def run_scenario(self, failure=None, scheme="rootless"):
        with tempfile.TemporaryDirectory() as temporary:
            root, state = Path(temporary), {"failure": failure, "builds": 0, "promotions": 0}
            journal_path = root / "build/release" / ("rootful" if scheme == "rootful" else "") / "publish.json"
            (root / "control").write_text((ROOT / "control").read_text())
            shutil.copytree(ROOT / "layout/DEBIAN", root / "layout/DEBIAN")

            def operation(arguments, **kwargs):
                if arguments[0] == "bash":
                    state["builds"] += 1
                    self.assertEqual(kwargs["env"]["RBX_PACKAGE_SCHEME"], scheme)
                    package_fixture(root / "packages/new.deb", kwargs["env"]["RBX_RELEASE_VERSION"], scheme=scheme)
                    return ""
                if arguments[1] == "deploy":
                    self.assertEqual(kwargs["cwd"], root)
                    if state["failure"] == "deploy":
                        state["failure"] = None
                        raise ValueError("Injected deploy failure")
                    return "https://fixture-release.vercel.app\n"
                self.assertEqual(arguments[1], "promote")
                state["promotions"] += 1
                journal = json.loads(journal_path.read_text())
                state["production"] = journal["manifest"]
                if state["failure"] == "promote-ack":
                    state["failure"] = None
                    raise ValueError("Injected uncertain promotion acknowledgement")
                return ""

            with mock.patch.object(release, "command", side_effect=operation), contextlib.redirect_stdout(io.StringIO()):
                if failure:
                    with self.assertRaises(ValueError):
                        FakePublisher(root, state, scheme).run("1.2.3")
                    journal = json.loads(journal_path.read_text())
                    self.assertNotEqual(journal["phase"], "complete")
                    owner = journal["owner"]
                    self.assertEqual(state["owner"], None if failure == "unlock-ack" else owner)
                    with self.assertRaises(ValueError):
                        FakePublisher(root, state, scheme).run("1.2.4")
                    FakePublisher(root, state, scheme).run(resume=True)
                    self.assertEqual(json.loads(journal_path.read_text())["owner"], owner)
                else:
                    FakePublisher(root, state, scheme).run("1.2.3")
            journal = json.loads(journal_path.read_text())
            self.assertEqual(journal["phase"], "complete")
            self.assertIsNone(state["owner"])
            self.assertEqual(state["builds"], 1)
            self.assertEqual(state["promotions"], 1)
            self.assertEqual(state["production"]["version"], "1.2.3")
            self.assertTrue((root / "cloud/public/apt" / apt.variant(scheme)["repository"] / "InRelease").is_file())

    def test_legacy_prepared_resume_requires_explicit_version_and_preserves_owner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); state={"failure":"lock-ack"}
            (root/"control").write_text((ROOT/"control").read_text())
            with self.assertRaises(ValueError): FakePublisher(root,state).run("1.2.3")
            path=root/"build/release/publish.json"; journal=json.loads(path.read_text()); owner=journal["owner"]
            journal.pop("requestedVersion"); path.write_text(json.dumps(journal))
            with self.assertRaisesRegex(ValueError,"explicit version"): FakePublisher(root,state).run(resume=True)
            def inspect_build(arguments,**kwargs):
                self.assertEqual(kwargs["env"]["RBX_RELEASE_VERSION"],"1.2.3")
                raise RuntimeError("stop fixture before build")
            with mock.patch.object(release,"command",side_effect=inspect_build), self.assertRaises(RuntimeError):
                FakePublisher(root,state).run("1.2.3",resume=True)
            self.assertEqual(json.loads(path.read_text())["owner"],owner)

    def test_complete_driver(self):
        for scheme in ("rootless", "rootful"):
            self.run_scenario(scheme=scheme)

    def test_interrupted_publication_resumes_without_rebuild_or_double_promotion(self):
        for scheme in ("rootless", "rootful"):
            for failure in ("lock-ack", "upload", "deploy", "stage-verify", "lock-check", "promote-ack", "production-verify", "unlock-ack", "peer-check"):
                with self.subTest(failure=failure, scheme=scheme):
                    self.run_scenario(failure, scheme)

    def test_unrecognized_journal_never_reaches_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            publisher = FakePublisher(Path(temporary), {})
            publisher.directory.mkdir(parents=True)
            release.atomic_json(publisher.journal_path, {"phase": "pretend-success", "formatVersion": 1, "configuration": publisher.config})
            with self.assertRaises(ValueError):
                publisher.run(resume=True)
            self.assertEqual(publisher.state, {})


class RealSignatures(unittest.TestCase):
    def test_actual_gpg_signature_authentication_corruption_and_bootstrap(self):
        gpg = shutil.which("gpg") or ("C:/Program Files/Git/usr/bin/gpg.exe" if Path("C:/Program Files/Git/usr/bin/gpg.exe").is_file() else None)
        if not gpg:
            self.fail("GPG is required for the actual signature test; install GnuPG or add it to PATH")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "gpg"
            home.mkdir(mode=0o700)
            git_gpg = os.name == "nt" and "/git/usr/bin/" in str(gpg).replace("\\", "/").lower()
            def gpg_path(value):
                value = str(value).replace("\\", "/")
                return "/" + value[0].lower() + value[2:] if git_gpg and len(value) > 2 and value[1:3] == ":/" else value
            environment = dict(os.environ, GNUPGHOME=gpg_path(home), PATH=str(Path(gpg).parent) + os.pathsep + os.environ.get("PATH", ""))
            real_command = release.command
            def portable_command(arguments, **kwargs):
                # Git's bundled GPG is an MSYS executable and needs /c/... paths.
                if git_gpg and Path(arguments[0]).stem == "gpg":
                    arguments = [gpg, *map(gpg_path, arguments[1:])]
                return real_command(arguments, **kwargs)
            patcher = mock.patch.object(release, "command", side_effect=portable_command)
            patcher.start()
            try:
                release.command([gpg, "--batch", "--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
                                 "RedditBox release fixture <fixture@invalid.example>", "rsa2048", "sign", "0"], env=environment)
                listing = release.command([gpg, "--batch", "--with-colons", "--list-secret-keys"], env=environment)
                fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
                publisher = FakePublisher(root, {})
                publisher.env, publisher.fingerprint = environment, fingerprint
                publisher.directory.mkdir(parents=True)
                artifact = b"debit"
                artifact_entry = entry()
                artifact_entry["sha256"] = apt.sha256(artifact)
                artifact_entry["blobURL"] = artifact_entry["blobURL"].replace("c" * 64, artifact_entry["sha256"])
                manifest, files = apt.generate_repository(artifact_entry, None, HOST, "2026-09-09T00:00:00Z")
                files["Release"] = apt.release_bytes(files, "Wed, 09 Sep 2026 00:00:00 GMT")
                signed = release.Publisher.sign(publisher, files)
                self.assertEqual(publisher.verify_inrelease(signed["InRelease"]), files["Release"])
                release.command([gpg, "--batch", "--verify", str(publisher.directory / "signed/Release.gpg"), str(publisher.directory / "signed/Release")], env=environment)
                with self.assertRaises(ValueError):
                    publisher.verify_inrelease(signed["InRelease"].replace(b"Origin: RedditBox", b"Origin: AttackerX"))
                publisher.fingerprint = FINGERPRINT
                with self.assertRaises(ValueError):
                    publisher.verify_inrelease(signed["InRelease"])
                publisher.fingerprint = fingerprint

                # A rootful release must preserve the real signed rootless repository.
                publisher.materialize(signed)
                peer_publisher = FakePublisher(root, {}, "rootful")
                peer_publisher.env, peer_publisher.fingerprint = environment, fingerprint
                peer_publisher.directory.mkdir(parents=True)
                peer_directory = root / "cloud/public/apt/redditbox"
                with mock.patch.object(peer_publisher, "published", return_value=(manifest, {})):
                    self.assertEqual(release.Publisher.check_peer(peer_publisher, local=True), manifest)
                    for name in ("Packages", "InRelease", "Release.gpg", "repository.json"):
                        original = (peer_directory / name).read_bytes()
                        (peer_directory / name).write_bytes(b"corrupted companion")
                        with self.subTest(companion=name), self.assertRaises(ValueError):
                            release.Publisher.check_peer(peer_publisher, local=True)
                        (peer_directory / name).write_bytes(original)
                    (peer_directory / "Packages.gz").unlink()
                    with self.assertRaises(ValueError):
                        release.Publisher.check_peer(peer_publisher, local=True)
                    (peer_directory / "Packages.gz").write_bytes(signed["Packages.gz"])
                newer, _ = apt.generate_repository(entry("1.2.4"), None, HOST, "later")
                for remote in (newer, None):
                    with mock.patch.object(peer_publisher, "published", return_value=(remote, {})), self.assertRaises(ValueError):
                        release.Publisher.check_peer(peer_publisher, local=True)

                def response(url, maximum, **kwargs):
                    name = url.split("/apt/redditbox/")[1]
                    return artifact if name.startswith("debs/") else signed[name]
                with mock.patch.object(release, "fetch", side_effect=response):
                    actual, _ = release.Publisher.published(publisher, publisher.repo, packages=True)
                    self.assertEqual(actual, manifest)
                with mock.patch.object(release, "fetch", side_effect=lambda url, *a, **kw: b"wrong" if "/debs/" in url else response(url, *a, **kw)), self.assertRaises(ValueError):
                    release.Publisher.published(publisher, publisher.repo, packages=True)
                corrupt = dict(signed, **{"repository.json": b"{}"})
                with mock.patch.object(release, "fetch", side_effect=lambda url, *a, **kw: corrupt[url.split("/apt/redditbox/")[1]]):
                    with self.assertRaises(ValueError):
                        release.Publisher.published(publisher, publisher.repo)
                for code in (401, 403, 429, 500):
                    with self.subTest(code=code), mock.patch.object(release, "fetch", side_effect=urllib.error.HTTPError("fixture", code, "fixture", {}, None)):
                        with self.assertRaises(urllib.error.HTTPError):
                            release.Publisher.published(publisher, publisher.repo, bootstrap=True)
                with mock.patch.object(release, "fetch", side_effect=urllib.error.HTTPError("fixture", 404, "fixture", {}, None)):
                    self.assertEqual(release.Publisher.published(publisher, publisher.repo, bootstrap=True), (None, {}))
                    with self.assertRaises(urllib.error.HTTPError):
                        release.Publisher.published(publisher, publisher.repo)
                def partial(url, *args, **kwargs):
                    if url.endswith("InRelease"):
                        raise urllib.error.HTTPError("fixture", 404, "fixture", {}, None)
                    return b"partial index"
                with mock.patch.object(release, "fetch", side_effect=partial), self.assertRaises(ValueError):
                    release.Publisher.published(publisher, publisher.repo, bootstrap=True)
            finally:
                patcher.stop()
                conf = Path(gpg).with_name("gpgconf.exe" if os.name == "nt" else "gpgconf")
                if conf.exists():
                    subprocess.run([str(conf), "--kill", "gpg-agent"], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


if __name__ == "__main__":
    unittest.main(verbosity=2)
