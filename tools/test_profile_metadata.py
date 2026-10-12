"""Portable organizational metadata wiring/isolation boundary checks.

Behavioral metadata validation runs in test_profile_metadata.m and cloud tests.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def read(path):
    return (ROOT / path).read_text(encoding="utf-8")

for path in ["daemon/RBXNetworkGate.m", "daemon/RBXProxyManager.m",
             "daemon/RBXConsistencyValidator.m", "daemon/RBXProfileGenerator.m"]:
    assert '[@"role"]' not in read(path), path
    assert '[@"notes"]' not in read(path), path
assert "RBXDefaultRole" in read("launcher/RBXSettingsViewController.m")
assert "RBXCreationDefaults(" in read("launcher/RBXLauncherViewController.m")
assert "RBXDefaultRole" in read("launcher/RBXCreationDefaults.h")
sync = read("daemon/RBXCloudSync.m")
assert 'profile[@"metadataDirty"]' in sync
assert "updateMetadata:published" in sync
assert "RBXMetadataAcknowledgesLocalEdit(profile, remoteMetadata[identifier])" in sync
assert "Local role/notes retained" in sync

# MDM protection must cover the full healthy inventory, independent of the
# launcher role filter or grouping used for the visible table.
launcher = read("launcher/RBXLauncherViewController.m")
mdm = launcher.split('actionWithTitle:@"Share MDM/VPN setup"')[1].split('actionWithTitle:@"Hide source Reddit app"')[0]
assert 'self.launcherState[@"containers"]' in mdm
assert '[allContainers filteredArrayUsingPredicate:' in mdm
assert 'self.containers' not in mdm
assert 'row[@"deletionState"]' in mdm and 'row[@"profileError"]' in mdm
assert 'exportFilesForContainers:available' in mdm
assert "discardMetadataChanges" in read("daemon/main.m")
assert "NSUTF32LittleEndianStringEncoding" in read("shared/RBXProfileMetadata.h")
print("profile metadata wiring and isolation boundaries passed")
