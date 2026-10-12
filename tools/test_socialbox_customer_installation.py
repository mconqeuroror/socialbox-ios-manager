#!/usr/bin/env python3
"""Isolated customer package lifecycle tests; no device or original code executes."""
import importlib.util
import hashlib
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "customer_candidate", ROOT / "scripts/build-socialbox-customer-candidate.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
sys.path.insert(0, str(ROOT / "scripts"))
from apt_repository import archive_members

FIXED_PATH = "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"
APP = "var/jb/Applications/SocialBox.app"
INSTALLER = "var/jb/usr/libexec/socialbox-prepare-installation"
OWNER = "var/jb/usr/libexec/socialbox-license-owner"
JOB = "var/jb/Library/LaunchDaemons/com.socialbox.licensing.plist"
SOURCE_STATE = (
    "var/jb/var/lib/socialbox-installation",
    "var/jb/var/lib/socialbox-license-pairing",
    "var/jb/var/lib/socialbox-container-configurations",
    "var/jb/var/lib/socialbox-container-pending",
    "var/jb/var/lib/.socialbox-container-pending.socialbox-root-pending-v1.json",
)
PACKAGE = "com.socialbox"
CUSTOMER_VERSION = "3.1.0-1+socialbox.customer.1"

# All administrative tools are synthetic. Native stat reads actual fixture modes;
# root identity is deliberately simulated, since these tests run unprivileged.
PROVIDER = r'''#!/bin/sh
set -eu
name=${0##*/}
printf '%s\000' "$name" "$@" >> "$FIXTURE_LOG"
printf '\000' >> "$FIXTURE_LOG"
case "$name" in
id) if [ "${1:-}" = -ru ]; then cat "$FIXTURE_STATE/real_uid"; else cat "$FIXTURE_STATE/uid"; fi;;
dpkg)
    case "${1:-}" in
    --print-architecture) cat "$FIXTURE_STATE/architecture";;
    --compare-versions) [ "$(cat "$FIXTURE_STATE/firmware_compatible")" = 1 ];;
    *) exit 91;;
    esac;;
dpkg-query)
    case "$*" in
    *firmware*) cat "$FIXTURE_STATE/firmware";;
    *) cat "$FIXTURE_STATE/inventory"; exit "$(cat "$FIXTURE_STATE/inventory_rc")";;
    esac;;
stat)
    path=$4
    [ "$1" = -L ] && [ "$2" = -c ] || exit 92
    mode=$(/usr/bin/stat -L -f '%Lp' "$path")
    links=$(/usr/bin/stat -L -f '%l' "$path")
    uid=0
    [ "$path" != "${FIXTURE_NONROOT_PATH:-}" ] || uid=501
    case "$3" in
    %u) printf '%s\n' "$uid";;
    %g) printf '0\n';;
    %a) printf '%s\n' "$mode";;
    %h) printf '%s\n' "$links";;
    %u:%g:%a) printf '%s:0:%s\n' "$uid" "$mode";;
    %u:%g:%a:%h) printf '%s:0:%s:%s\n' "$uid" "$mode" "$links";;
    *) exit 92;;
    esac;;
sha256sum) exec /usr/bin/shasum -a 256 "$1";;
launchctl)
    case "${1:-}" in
    print) [ "$(cat "$FIXTURE_STATE/loaded")" = 1 ];;
    bootstrap|kickstart) [ "$(cat "$FIXTURE_STATE/launch_rc")" = 0 ] || exit 94
        printf '1\n' > "$FIXTURE_STATE/loaded";;
    bootout) printf '0\n' > "$FIXTURE_STATE/loaded";;
    *) exit 94;;
    esac;;
uicache) exit "$(cat "$FIXTURE_STATE/uicache_rc")";;
jbroot) exit 95;;
*) exit 96;;
esac
'''
PREPARATION_PROVIDER = r'''#!/bin/sh
set -eu
printf '%s\000' prepare-installation "$@" >> "$FIXTURE_LOG"
printf '\000' >> "$FIXTURE_LOG"
[ "$#" = 1 ] && [ "$1" = check ] || exit 93
exit "$(cat "$FIXTURE_STATE/check_rc")"
'''


def witness(path):
    """Capture node identities and bytes without following links or reading FIFOs."""
    found = {}
    for node in [path, *sorted(path.rglob("*"))]:
        metadata = node.lstat()
        value = (metadata.st_dev, metadata.st_ino, metadata.st_mode,
                 metadata.st_uid, metadata.st_gid, metadata.st_size,
                 metadata.st_mtime_ns, metadata.st_ctime_ns)
        if stat.S_ISREG(metadata.st_mode): value += (node.read_bytes(),)
        elif stat.S_ISLNK(metadata.st_mode): value += (os.readlink(node),)
        found[str(node.relative_to(path))] = value
    return found


class Fixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="socialbox-customer-fixture-")
        self.root = Path(self.temporary.name)
        self.bootstrap = self.root / "jb"
        self.commands = self.root / "commands"
        self.state = self.root / "provider-state"
        self.log = self.root / "calls"
        self.bootstrap.mkdir(mode=0o755)
        self.commands.mkdir(mode=0o755)
        self.state.mkdir(mode=0o700)
        self.log.touch()
        for name, value in {
            "uid": "0", "real_uid": "0", "architecture": "iphoneos-arm64", "firmware": "16.7.16",
            "firmware_compatible": "1", "inventory": "", "inventory_rc": "0",
            "loaded": "0", "check_rc": "0", "launch_rc": "0", "uicache_rc": "0",
        }.items(): self.set(name, value)
        for name in ("id", "stat", "sha256sum", "dpkg", "dpkg-query", "launchctl", "uicache"):
            destination = self.commands / name
            destination.write_text(PROVIDER)
            destination.chmod(0o755)
        for name in ("dpkg", "dpkg-query"):
            destination = self.bootstrap / "usr/bin" / name
            destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            destination.symlink_to(self.commands / name)
        self.payload = {
            APP + "/SocialBox": b"inert synthetic app bytes\n",
            APP + "/Info.plist": b"inert synthetic metadata\n",
            INSTALLER: PREPARATION_PROVIDER.encode(),
            OWNER: b"inert synthetic owner bytes\n",
            JOB: b"inert synthetic licensing job metadata\n",
        }
        self.modes = {name: (0o755 if name in (APP + "/SocialBox", INSTALLER, OWNER) else 0o644)
                      for name in self.payload}
        # Existing fixed parents contain no payload/source state nodes.
        for name in (*self.payload, *SOURCE_STATE):
            self.path(name).parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        shim = self.path("var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate")
        shim.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        shim.write_bytes(b"inert shim metadata")
        shim.chmod(0o644)
        self.scripts, self.preflight = c.customer_scripts(self.payload, self.modes)
        self.env = os.environ.copy()
        self.env.update(FIXTURE_LOG=str(self.log), FIXTURE_STATE=str(self.state))

    def close(self): self.temporary.cleanup()

    def path(self, name):
        if not name.startswith("var/jb/"): raise ValueError(name)
        return self.bootstrap / name.removeprefix("var/jb/")

    def set(self, name, value): (self.state / name).write_text(value)

    def inventory(self, records):
        self.set("inventory", "".join(f"{name}\tiphoneos-arm64\t{version}\t{status}\n"
                                    for name, status, version in records))

    def install_payload(self):
        for name, data in self.payload.items():
            destination = self.path(name)
            destination.write_bytes(data)
            destination.chmod(self.modes[name])

    def existing_source_metadata(self):
        # Synthetic pre-existing nodes only; this is not a preparation issuer or
        # a fixture for the native prepared-record validator.
        for name in SOURCE_STATE[:-1]:
            destination = self.path(name)
            destination.mkdir(mode=0o700)
            (destination / "sentinel").write_bytes(b"pre-existing synthetic source metadata")
        self.path(SOURCE_STATE[-1]).write_bytes(b"pre-existing synthetic pending root marker")

    def run(self, name, *arguments):
        raw = self.preflight if name == "preflight" else self.scripts[name]
        text = raw.decode() if isinstance(raw, bytes) else raw
        if FIXED_PATH not in text: raise AssertionError("Missing fixed production PATH")
        # Rewriting exists only in this test; production has no caller root/PATH seam.
        text = text.replace("/var/jb", str(self.bootstrap))
        rewritten_path = FIXED_PATH.replace("/var/jb", str(self.bootstrap))
        text = text.replace(rewritten_path, f"PATH={self.commands}:/usr/bin:/bin")
        self.log.write_bytes(b"")
        return subprocess.run(["/bin/sh", "-c", text, "fixture", *arguments],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def calls(self):
        return [tuple(value.decode() for value in entry.split(b"\0"))
                for entry in self.log.read_bytes().split(b"\0\0") if entry]

    def effects(self):
        return [call for call in self.calls() if call[0] in ("prepare-installation", "launchctl", "uicache")]


class CustomerInstallation(unittest.TestCase):
    executions = 0

    def fixture(self):
        fixture = Fixture()
        self.addCleanup(fixture.close)
        return fixture

    def execute(self, fixture, name, *arguments):
        type(self).executions += 1
        return fixture.run(name, *arguments)

    def assert_refused_unchanged(self, fixture, name, *arguments):
        before = witness(fixture.bootstrap)
        foreign = {node: witness(node) for node in (fixture.root / "foreign-parent", fixture.root / "moved-app")
                   if node.is_dir()}
        result = self.execute(fixture, name, *arguments)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(witness(fixture.bootstrap), before)
        for node, unchanged in foreign.items(): self.assertEqual(witness(node), unchanged)
        self.assertEqual(fixture.effects(), [])
        return result

    def test_scope_and_script_composition_are_check_only(self):
        fixture = self.fixture()
        self.assertEqual(set(fixture.scripts), {"preinst", "postinst", "prerm"})
        scope = c.candidate_scope()
        self.assertIs(scope["freshInstallReady"], False)
        self.assertIs(scope["customerDeliveryReady"], False)
        postinst = fixture.scripts["postinst"].decode()
        self.assertIn("/var/jb/usr/libexec/socialbox-prepare-installation check", postinst)
        self.assertNotIn("socialbox-prepare-installation\n", postinst)
        for raw in (*fixture.scripts.values(), fixture.preflight):
            text = raw.decode() if isinstance(raw, bytes) else raw
            self.assertIn(FIXED_PATH, text)
            self.assertNotIn("LBXPrepareLicenseInstallation", text)
            self.assertNotIn("create-pristine", text)
            self.assertNotIn("rm -", text)
            # Paths passed to read-only verification functions are not commands.
            for line in text.splitlines():
                command = line.strip().split()
                if command and command[0] == "/var/jb/usr/libexec/socialbox-prepare-installation":
                    self.assertEqual(command[1], "check")
        self.assertLess(postinst.index("socialbox-prepare-installation check"), postinst.index("launchctl"))
        self.assertLess(postinst.index("launchctl"), postinst.index("uicache"))

    def test_absent_catalog_and_destinations_permit_unpack_only(self):
        fixture = self.fixture()
        for script in ("preflight", "preinst"):
            with self.subTest(script=script):
                before = witness(fixture.bootstrap)
                result = self.execute(fixture, script, "install")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(witness(fixture.bootstrap), before)
                self.assertEqual(fixture.effects(), [])
                catalogs = [call for call in fixture.calls() if call[0] == "dpkg-query" and
                            not any("firmware" in arg for arg in call[1:])]
                self.assertEqual(len(catalogs), 1)
                self.assertFalse(any(PACKAGE in arg or "com.redditbox" in arg for arg in catalogs[0][1:]))
                for call in fixture.calls():
                    if call[0] == "dpkg": self.assertIn(call[1], ("--print-architecture", "--compare-versions"))

    def test_catalog_columns_and_identity_cannot_hide_empty_or_foreign_fields(self):
        fixture = self.fixture()
        invalid = (
            "example\tiphoneos-arm64\t1.0\tinstalled\t\n",
            "\texample\tiphoneos-arm64\t1.0\tinstalled\n",
            "example\t\tiphoneos-arm64\t1.0\tinstalled\n",
            "example\tiphoneos-arm64\t\t1.0\tinstalled\n",
            "example\tiphoneos-arm64\t1.0\t\tinstalled\n",
            "\t\t\t\n",
            "\nexample\tiphoneos-arm64\t1.0\tinstalled\n",
            "example\tiphoneos-arm64\t1.0\tinstalled\n\nother\tiphoneos-arm64\t2.0\tinstalled\n",
            " com.socialbox\tiphoneos-arm64\t1.0\tinstalled\n",
            "com.socialbox \tiphoneos-arm64\t1.0\tinstalled\n",
            "example:arm64\tiphoneos-arm64\t1.0\tinstalled\n",
            "example:arm64:arm64\tarm64\t1.0\tinstalled\n",
            "Example\tiphoneos-arm64\t1.0\tinstalled\n",
            "example*\tiphoneos-arm64\t1.0\tinstalled\n",
            "-example\tiphoneos-arm64\t1.0\tinstalled\n",
            "example\tiphoneos_arm64\t1.0\tinstalled\n",
            "example\tiphoneos-arm64\t1.0 injected\tinstalled\n",
            "example\tiphoneos-arm64\tfirst\tinstalled\n",
            f"{PACKAGE}\t\tiphoneos-arm64\t{CUSTOMER_VERSION}\thalf-installed\n",
            f"{PACKAGE}:other\tiphoneos-arm64\t{CUSTOMER_VERSION}\thalf-installed\n",
        )
        for raw in invalid:
            fixture.set("inventory", raw)
            for script in ("preflight", "preinst"):
                with self.subTest(script=script, catalog=repr(raw)):
                    self.assert_refused_unchanged(fixture, script, "install")

    def test_unknown_catalog_state_words_refuse_without_effects(self):
        fixture = self.fixture()
        for status in ("future-state", "Installed", "ii ", "not-installed\r"):
            fixture.set("inventory", f"example\tiphoneos-arm64\t1.0\t{status}\n")
            for script in ("preflight", "preinst"):
                with self.subTest(script=script, status=status):
                    self.assert_refused_unchanged(fixture, script, "install")

    def test_duplicate_catalog_identity_is_per_package_and_architecture(self):
        fixture = self.fixture()
        invalid = (
            "example\tiphoneos-arm64\t1.0\tinstalled\n" * 2,
            "example\tiphoneos-arm64\t1.0\tinstalled\nexample\tiphoneos-arm64\t2.0\tconfig-files\n",
            "example\tiphoneos-arm64\t1.0\tinstalled\nexample:iphoneos-arm64\tiphoneos-arm64\t1.0\tinstalled\n",
        )
        for raw in invalid:
            fixture.set("inventory", raw)
            for script in ("preflight", "preinst"):
                with self.subTest(script=script, catalog=repr(raw)):
                    self.assert_refused_unchanged(fixture, script, "install")
        fixture.set("inventory", "example\tiphoneos-arm64\t1.0\tinstalled\nexample:arm64\tarm64\t2.0\tinstalled\n")
        for script in ("preflight", "preinst"):
            before = witness(fixture.bootstrap)
            result = self.execute(fixture, script, "install")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(witness(fixture.bootstrap), before)
            self.assertEqual(fixture.effects(), [])

    def test_known_catalog_state_words_and_standard_versions_preserve_unpack_scope(self):
        fixture = self.fixture()
        states = ("not-installed", "config-files", "half-installed", "unpacked",
                  "half-configured", "triggers-awaited", "triggers-pending", "installed")
        fixture.set("inventory", "".join(f"example{i}\tiphoneos-arm64\t1:2.0~rc1+build1-2\t{status}\n"
                                         for i, status in enumerate(states)))
        for script in ("preflight", "preinst"):
            before = witness(fixture.bootstrap)
            result = self.execute(fixture, script, "install")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(witness(fixture.bootstrap), before)
            self.assertEqual(fixture.effects(), [])

    def test_incoming_half_installed_record_has_exact_narrow_boundary(self):
        fixture = self.fixture()
        fixture.inventory([(PACKAGE, "half-installed", CUSTOMER_VERSION)])
        self.assert_refused_unchanged(fixture, "preflight", "install")
        result = self.execute(fixture, "preinst", "install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture.effects(), [])
        for action in ((), ("install", ""), ("install", "old-version"),
                       ("upgrade",), ("abort-upgrade",), ("",)):
            with self.subTest(action=action): self.assert_refused_unchanged(fixture, "preinst", *action)
        for status, version in (("installed", CUSTOMER_VERSION), ("config-files", CUSTOMER_VERSION),
                                ("half-configured", CUSTOMER_VERSION), ("unpacked", CUSTOMER_VERSION),
                                ("half-installed", "3.1.0-1")):
            with self.subTest(status=status, version=version):
                fixture.inventory([(PACKAGE, status, version)])
                self.assert_refused_unchanged(fixture, "preinst", "install")

    def test_catalog_conflicts_and_incomplete_inventory_refuse(self):
        fixture = self.fixture()
        roots = (PACKAGE, "com.redditbox", PACKAGE + ".roothide")
        for package in (*roots, *(name + ":iphoneos-arm64" for name in roots)):
            for status in ("installed", "config-files", "not-installed"):
                # Valid fields must reach the history rule, not an earlier
                # malformed-row refusal that would mask a missing conflict guard.
                fixture.inventory([(package, status, "3.0-1")])
                for script in ("preflight", "preinst"):
                    with self.subTest(package=package, status=status, script=script):
                        result = self.assert_refused_unchanged(fixture, script, "install")
                        self.assertIn("migration", result.stderr)
        for inventory in ("", "firmware\tall\t16.7.16\tinstalled\n"):
            fixture.set("inventory", inventory)
            fixture.set("inventory_rc", "1")
            for script in ("preflight", "preinst"):
                with self.subTest(partial=bool(inventory), script=script):
                    self.assert_refused_unchanged(fixture, script, "install")

    def test_malformed_duplicate_or_wrong_architecture_catalog_records_refuse(self):
        fixture = self.fixture()
        records = (
            f"{PACKAGE}\tiphoneos-arm\t{CUSTOMER_VERSION}\thalf-installed\n",
            f"{PACKAGE}\tiphoneos-arm64\t{CUSTOMER_VERSION}\n",
            "malformed\n",
            f"{PACKAGE}\tiphoneos-arm64\t{CUSTOMER_VERSION}\thalf-installed\textra\n",
            2 * f"{PACKAGE}\tiphoneos-arm64\t{CUSTOMER_VERSION}\thalf-installed\n",
        )
        for record in records:
            fixture.set("inventory", record)
            for script in ("preflight", "preinst"):
                with self.subTest(record=record, script=script):
                    self.assert_refused_unchanged(fixture, script, "install")

    def test_matching_manager_qualifier_keeps_the_exact_incoming_boundary(self):
        fixture = self.fixture()
        fixture.inventory([(PACKAGE + ":iphoneos-arm64", "half-installed", CUSTOMER_VERSION)])
        before = witness(fixture.bootstrap)
        result = self.execute(fixture, "preinst", "install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(witness(fixture.bootstrap), before)
        self.assertEqual(fixture.effects(), [])
        refused = self.assert_refused_unchanged(fixture, "preflight", "install")
        self.assertIn("migration", refused.stderr)

    def test_absent_payload_parents_are_checked_without_creation(self):
        fixture = self.fixture()
        fixture.path(APP).rmdir()
        fixture.path("var/jb/usr/libexec").rmdir()
        fixture.path("var/jb/Library/LaunchDaemons").rmdir()
        for script in ("preflight", "preinst"):
            with self.subTest(script=script):
                before = witness(fixture.bootstrap)
                result = self.execute(fixture, script, "install")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(witness(fixture.bootstrap), before)
                self.assertEqual(fixture.effects(), [])

    def test_source_nodes_of_every_type_refuse_without_changes(self):
        for relative in SOURCE_STATE:
            for kind in ("file", "directory", "dangling-link", "fifo"):
                with self.subTest(path=relative, kind=kind):
                    fixture = self.fixture()
                    path = fixture.path(relative)
                    if kind == "file": path.write_bytes(b"existing owner provenance")
                    elif kind == "directory":
                        path.mkdir(); (path / "sentinel").write_bytes(b"existing owner provenance")
                    elif kind == "dangling-link": path.symlink_to(fixture.root / "absent")
                    else: os.mkfifo(path)
                    for script in ("preflight", "preinst"):
                        self.assert_refused_unchanged(fixture, script, "install")

    def test_payload_collisions_include_dangling_links(self):
        for relative in (APP + "/SocialBox", APP + "/Info.plist", INSTALLER, OWNER, JOB):
            for kind in ("file", "directory", "dangling-link"):
                with self.subTest(path=relative, kind=kind):
                    fixture = self.fixture()
                    path = fixture.path(relative)
                    if kind == "file": path.write_bytes(b"foreign bytes")
                    elif kind == "directory": path.mkdir()
                    else: path.symlink_to(fixture.root / "absent")
                    for script in ("preflight", "preinst"):
                        self.assert_refused_unchanged(fixture, script, "install")

    def test_unsafe_parents_fail_before_absence_is_interpreted(self):
        for relative in ("var/jb/var/lib", "var/jb/usr/libexec"):
            for kind in ("alias", "dangling-link", "file", "writable", "nonroot", "missing"):
                with self.subTest(parent=relative, kind=kind):
                    fixture = self.fixture()
                    path = fixture.path(relative)
                    if kind == "writable": path.chmod(0o777)
                    elif kind == "nonroot": fixture.env["FIXTURE_NONROOT_PATH"] = str(path)
                    elif kind == "missing":
                        if relative == "var/jb/usr/libexec": continue
                        path.rmdir()
                    else:
                        path.rmdir()
                        if kind == "file": path.write_bytes(b"foreign parent")
                        elif kind == "dangling-link": path.symlink_to(fixture.root / "absent")
                        else:
                            foreign = fixture.root / "foreign-parent"; foreign.mkdir()
                            (foreign / "sentinel").write_bytes(b"foreign bytes")
                            path.symlink_to(foreign)
                    for script in ("preflight", "preinst"):
                        self.assert_refused_unchanged(fixture, script, "install")

    def test_rootless_role_prefix_architecture_and_roothide_are_required(self):
        for issue in ("uid", "real_uid", "architecture", "firmware", "prefix", "roothide"):
            with self.subTest(issue=issue):
                fixture = self.fixture()
                if issue in ("uid", "real_uid"): fixture.set(issue, "501")
                elif issue == "architecture": fixture.set("architecture", "iphoneos-arm")
                elif issue == "firmware": fixture.set("firmware_compatible", "0")
                elif issue == "prefix": fixture.env["THEOS_PACKAGE_INSTALL_PREFIX"] = "/alternate"
                else:
                    (fixture.commands / "jbroot").write_text(PROVIDER)
                    (fixture.commands / "jbroot").chmod(0o755)
                for script in ("preflight", "preinst"):
                    self.assert_refused_unchanged(fixture, script, "install")

    def test_configuration_and_removal_require_real_and_effective_root_before_effects(self):
        for identity in ("uid", "real_uid"):
            fixture = self.fixture(); fixture.install_payload(); fixture.existing_source_metadata()
            fixture.set(identity, "501"); fixture.set("loaded", "1")
            for script, action in (("postinst", "configure"), ("prerm", "remove"), ("prerm", "deconfigure")):
                with self.subTest(identity=identity, script=script, action=action):
                    self.assert_refused_unchanged(fixture, script, action)

    def test_configuration_and_abort_recovery_check_before_start_and_register(self):
        fixture = self.fixture(); fixture.install_payload(); fixture.existing_source_metadata()
        for action in ("configure", "configure", "abort-upgrade", "abort-remove", "abort-deconfigure"):
            with self.subTest(action=action):
                before = witness(fixture.bootstrap)
                result = self.execute(fixture, "postinst", action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(witness(fixture.bootstrap), before)
                effects = fixture.effects()
                self.assertEqual(effects[0], ("prepare-installation", "check"))
                self.assertEqual(effects[-1], ("uicache", "-p", str(fixture.path(APP))))
                self.assertEqual(sum(call[0] == "prepare-installation" for call in effects), 1)
                self.assertEqual([call[1] for call in effects if call[0] == "launchctl"],
                                 ["print", "bootstrap"] if action == "configure" and not fixture.__dict__.get("configured")
                                 else ["print", "kickstart"])
                for call in effects:
                    if call[0] == "launchctl": self.assertIn("com.socialbox.licensing", " ".join(call))
                fixture.configured = True

    def test_failed_existing_check_never_initializes_repairs_or_starts(self):
        for kind in ("all-missing", "partial-file", "partial-directory", "dangling-link"):
            fixture = self.fixture(); fixture.install_payload(); fixture.set("check_rc", "1")
            anchor = fixture.path(SOURCE_STATE[0])
            if kind == "partial-file": anchor.write_bytes(b"partial established provenance")
            elif kind == "partial-directory":
                anchor.mkdir(); (anchor / "intent").write_bytes(b"partial established intent")
            elif kind == "dangling-link": anchor.symlink_to(fixture.root / "lost-owner-state")
            for action in ("configure", "configure", "abort-upgrade", "abort-remove", "abort-deconfigure"):
                with self.subTest(state=kind, action=action):
                    before = witness(fixture.bootstrap)
                    result = self.execute(fixture, "postinst", action)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(witness(fixture.bootstrap), before)
                    self.assertEqual(fixture.effects(), [("prepare-installation", "check")])

    def test_changed_payload_and_unsafe_parents_refuse_before_check(self):
        for relative, issue in ((APP + "/SocialBox", "hash"), (INSTALLER, "mode"),
                                (OWNER, "missing"), (JOB, "link"),
                                (APP + "/Info.plist", "hardlink"),
                                ("var/jb/usr/libexec", "parent-mode"),
                                ("var/jb/Applications/SocialBox.app", "parent-alias")):
            with self.subTest(path=relative, issue=issue):
                fixture = self.fixture(); fixture.install_payload()
                path = fixture.path(relative)
                if issue == "hash": path.write_bytes(b"different installed bytes")
                elif issue == "mode": path.chmod(0o700)
                elif issue == "missing": path.unlink()
                elif issue == "link":
                    path.unlink(); path.symlink_to(fixture.root / "absent")
                elif issue == "hardlink": os.link(path, fixture.root / "external-hardlink")
                elif issue == "parent-mode": path.chmod(0o777)
                else:
                    path.rename(fixture.root / "moved-app")
                    path.symlink_to(fixture.root / "moved-app")
                self.assert_refused_unchanged(fixture, "postinst", "configure")

    def test_service_failure_does_not_register_and_registration_failure_preserves_state(self):
        for issue in ("launch_rc", "uicache_rc"):
            with self.subTest(issue=issue):
                fixture = self.fixture(); fixture.install_payload(); fixture.existing_source_metadata()
                fixture.set(issue, "1")
                before = witness(fixture.bootstrap)
                result = self.execute(fixture, "postinst", "configure")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(witness(fixture.bootstrap), before)
                effects = fixture.effects()
                self.assertEqual(effects[0], ("prepare-installation", "check"))
                self.assertEqual(sum(call[0] == "prepare-installation" for call in effects), 1)
                if issue == "launch_rc": self.assertFalse(any(call[0] == "uicache" for call in effects))
                else: self.assertEqual(effects[-1], ("uicache", "-p", str(fixture.path(APP))))

    def test_archive_contains_only_canonical_controls_and_exact_payload(self):
        fixture = self.fixture()
        fixture.modes[APP + "/SocialBox"] = 0o6755
        scripts, _ = c.customer_scripts(fixture.payload, fixture.modes)
        package = c.build_customer_deb(fixture.payload, scripts, fixture.modes,
                                       "firmware (>= 15.0), mobilesubstrate")
        members = archive_members(package)
        self.assertEqual(set(members), {"debian-binary", "control.tar.gz", "data.tar.gz"})
        with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:*") as archive:
            entries = {item.name: item for item in archive if item.isfile()}
            self.assertEqual(set(entries), {"control", "md5sums", "preinst", "postinst", "prerm"})
            self.assertNotIn("postrm", entries)
            for name in scripts:
                self.assertEqual(entries[name].mode, 0o755)
                self.assertEqual(archive.extractfile(entries[name]).read(), scripts[name])
            control = archive.extractfile(entries["control"]).read().decode()
            self.assertIn("Version: " + CUSTOMER_VERSION + "\n", control)
            self.assertIn("X-SocialBox-Status: private-first-install-check-only-unvalidated\n", control)
            self.assertIn("Depends: firmware (>= 16.0), mobilesubstrate\n", control)
            self.assertIn("independently trusted external first-preparation transaction", control)
            expected_md5 = "".join(f"{hashlib.md5(data).hexdigest()}  {name}\n"
                                   for name, data in sorted(fixture.payload.items())).encode()
            self.assertEqual(archive.extractfile(entries["md5sums"]).read(), expected_md5)
        with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:*") as archive:
            entries = list(archive)
            files = {item.name: item for item in entries if item.isfile()}
            self.assertEqual(set(files), set(fixture.payload))
            self.assertTrue(all(item.isfile() or item.isdir() for item in entries))
            for item in entries:
                self.assertEqual((item.uid, item.gid), (0, 0))
                self.assertEqual(item.mtime, 0)
                if item.isdir(): self.assertEqual(item.mode, 0o755)
            for name, data in fixture.payload.items():
                self.assertEqual(files[name].mode, fixture.modes[name])
                self.assertEqual(archive.extractfile(files[name]).read(), data)
            for forbidden in SOURCE_STATE:
                self.assertFalse(any(name == forbidden or name.startswith(forbidden + "/") for name in files))
        self.assertIs(c.candidate_scope()["freshInstallReady"], False)
        self.assertIs(c.candidate_scope()["customerDeliveryReady"], False)

    def test_archive_rejects_altered_or_additional_lifecycle_controls(self):
        fixture = self.fixture()
        for change in ("postrm", "postinst", "missing-prerm"):
            with self.subTest(change=change):
                scripts = dict(fixture.scripts)
                if change == "postrm": scripts["postrm"] = b"#!/bin/sh\nexit 0\n"
                elif change == "postinst": scripts["postinst"] = b"#!/bin/sh\n# foreign lifecycle control\nexit 0\n"
                else: del scripts["prerm"]
                with self.assertRaisesRegex(ValueError, "generated check-only"):
                    c.build_customer_deb(fixture.payload, scripts, fixture.modes, "mobilesubstrate")

    def test_source_state_escaping_writable_and_incomplete_inputs_cannot_be_packaged(self):
        fixture = self.fixture()
        cases = []
        for path in SOURCE_STATE:
            for suffix in ("", "/unexpected-record"):
                payload = dict(fixture.payload); modes = dict(fixture.modes)
                payload[path + suffix] = b"must never enter package"; modes[path + suffix] = 0o600
                cases.append((path + suffix, payload, modes))
        for path in ("var/jb/../outside", "var/jb/usr//invalid", "/var/jb/usr/absolute", "var/jb/usr/space name"):
            payload = dict(fixture.payload); modes = dict(fixture.modes)
            payload[path] = b"unsafe path"; modes[path] = 0o600
            cases.append((path, payload, modes))
        for mode in (0o777, 0o664):
            modes = dict(fixture.modes); modes[INSTALLER] = mode
            cases.append((str(mode), dict(fixture.payload), modes))
        for change in ("missing-mode", "extra-mode", "missing-payload", "missing-required-input"):
            payload = dict(fixture.payload); modes = dict(fixture.modes)
            if change == "missing-mode": del modes[INSTALLER]
            elif change == "extra-mode": modes["var/jb/usr/libexec/extra"] = 0o755
            elif change == "missing-payload": del payload[INSTALLER]
            else: del payload[INSTALLER]; del modes[INSTALLER]
            cases.append((change, payload, modes))
        for label, payload, modes in cases:
            with self.subTest(input=label):
                with self.assertRaises(ValueError): c.customer_scripts(payload, modes)
                with self.assertRaises(ValueError):
                    c.build_customer_deb(payload, fixture.scripts, modes, "mobilesubstrate")
        for dependencies in ("mobilesubstrate\nInjected: yes", "mobilesubstrate\rInjected: yes"):
            with self.subTest(dependencies=dependencies), self.assertRaises(ValueError):
                c.build_customer_deb(fixture.payload, fixture.scripts, fixture.modes, dependencies)

    def test_remove_and_deconfigure_stop_only_licensing_preserving_all_state(self):
        fixture = self.fixture(); fixture.install_payload()
        for relative in SOURCE_STATE:
            path = fixture.path(relative); path.mkdir()
            (path / "sentinel").write_bytes(b"owner state must survive removal")
        for action in ("remove", "deconfigure"):
            with self.subTest(action=action):
                fixture.set("loaded", "1")
                before = witness(fixture.bootstrap)
                result = self.execute(fixture, "prerm", action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(witness(fixture.bootstrap), before)
                self.assertEqual(fixture.effects(), [("launchctl", "print", "system/com.socialbox.licensing"),
                                                     ("launchctl", "bootout", "system/com.socialbox.licensing")])

    def test_unsupported_upgrade_refuses_and_other_lifecycle_actions_have_no_effects(self):
        fixture = self.fixture(); fixture.install_payload(); fixture.set("loaded", "1")
        self.assert_refused_unchanged(fixture, "prerm", "upgrade", "next-version")
        for script, action in (("prerm", "failed-upgrade"), ("prerm", "unknown"),
                               ("postinst", "unknown"), ("postinst", "abort-install")):
            with self.subTest(script=script, action=action):
                before = witness(fixture.bootstrap)
                result = self.execute(fixture, script, action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(witness(fixture.bootstrap), before)
                self.assertEqual(fixture.effects(), [])


if __name__ == "__main__":
    program = unittest.main(verbosity=2, exit=False)
    print(f"Isolated lifecycle executions: {CustomerInstallation.executions}")
    sys.exit(0 if program.result.wasSuccessful() else 1)
