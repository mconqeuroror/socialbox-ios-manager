#!/usr/bin/env python3
"""Host-side invariants for the per-profile cloned-app architecture."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "vpn_generator", ROOT / "scripts" / "generate-per-app-vpn-profile.py"
)
assert SPEC and SPEC.loader
vpn_generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vpn_generator)


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def main() -> int:
    profiles = [f"profile-{index:02d}" for index in range(30)]
    bundle_ids = [vpn_generator.bundle_id(profile) for profile in profiles]
    assert len(set(bundle_ids)) == 30
    assert all(value.startswith("com.redditbox.profile.p") for value in bundle_ids)
    assert all(len(value) < 64 for value in bundle_ids)

    clone = text("daemon/RBXCloneManager.m")
    entitlement_policy = clone[
        clone.index("- (NSDictionary *)_entitlementsForBundleIdentifier"):
        clone.index("- (BOOL)_rewriteAndSignBundle")
    ]
    assert '"keychain-access-groups"' in clone
    assert "com.apple.security.application-groups" not in entitlement_policy
    assert "aps-environment" not in entitlement_policy
    assert "RedditBoxProfile.json" in clone
    assert "copyfile" in clone and "COPYFILE_CLONE" in clone
    assert "_installIPA" in clone and '"appinst"' in clone
    assert "_archiveTransactionRoot" in clone
    assert "RBXSpawnCapturingStdout" in clone
    assert "installd did not allocate both bundle and data containers" in clone

    entry = text("tweak/RedditBox.xm")
    assert entry.index("RBXMarkAllHooksReady(installed,") < entry.index("RBXInstallIsolationSentinel();")
    sentinel = text("tweak/LeakDetection/RBXIsolationSentinel.m")
    editor = text("launcher/RBXIdentityViewController.m")
    assert 'self.sentinelSaveButton.enabled = !self.pendingRequestId.length;' in editor
    assert '[self.catalogButtons addObject:self.sentinelSaveButton]' not in editor
    assert 'addCatalogButton:@"Save sentinel settings"' not in editor
    assert "RBXSentinelRegister(control[" in sentinel
    assert "RBXBeginInternalControlFileAccess" not in sentinel
    assert "closeTraffic" not in sentinel and "openTraffic" not in sentinel
    sentinel_policy = (ROOT / "shared/RBXIsolationSentinel.h").read_text()
    assert "SecItemCopyMatching" in sentinel and "RBXSentinelReadDefaults([NSUserDefaults new]" in sentinel
    assert "addSuiteNamed" in sentinel_policy and "objectForKey" in sentinel_policy and "removeSuiteNamed" in sentinel_policy
    sentinel_controller = (ROOT / "daemon/RBXSentinelController.m").read_text()
    assert 'NSArray *rows = RBXSentinelNormalizedRows(report[@"rows"])' in sentinel_controller
    daemon_main = text("daemon/main.m")
    assert daemon_main.index("[RBXSentinelController setProcessIdentityProvider:") < daemon_main.index("[RBXLauncherState startPeriodicPublisherWithRegistry:")
    assert "return sProc.activeCloneIdentity;" in daemon_main
    assert "attributesOfItemAtPath" in sentinel and "fileHandleForReadingFromURL" in sentinel
    assert "RBXSentinelCloseReadHandle(handle)" in sentinel
    assert "RBXInstallPathHooks(mgr)" not in entry
    assert "RBXInstallKeychainHooks(mgr)" not in entry
    assert "RBXInstallRequestAudit()" not in entry

    manager = text("tweak/Container/RBXContainerManager.xm")
    assert "Library/Application Support/RedditBox/profile.json" in manager
    assert "com.redditbox.activeContainer" not in manager
    assert "SecTaskCopyValueForEntitlement" in manager
    assert "keychain-access-groups" in manager
    assert "RBXCloneKeychainProbe" in manager

    gate = text("daemon/RBXNetworkGate.m")
    assert '@"bundleIdentifier"' in gate
    assert '@"scope"] isEqualToString:@"per-app"' in gate

    print("PASS: 30 deterministic unique clone identities")
    print("PASS: legacy path/keychain isolation is not installed")
    print("PASS: clone-local identity and generation-bound per-app lease checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
