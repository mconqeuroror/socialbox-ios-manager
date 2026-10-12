#!/usr/bin/env python3
"""Host-side invariants for per-container identity customization."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


registry = text("daemon/RBXContainerRegistry.m")
daemon = text("daemon/main.m")
state = text("daemon/RBXLauncherState.m")
launcher = text("launcher/RBXLauncherViewController.m")
editor = text("launcher/RBXIdentityViewController.m")
validator = text("daemon/RBXConsistencyValidator.m")
cloud = text("daemon/RBXCloudSync.m")

for action in ("previewIdentity", "applyIdentity"):
    assert f'@"{action}"' in daemon
    assert f'@"{action}"' in editor

assert "Identity & Cloaking" in launcher
assert "Automatically fill" in editor and "Set manually" in editor
assert "[stack addArrangedSubview:self.modeControl]" in editor
choices_method = editor[editor.index("- (NSDictionary *)choices {"):editor.index("- (void)checkConsistency {")]
assert '@"mode": @"manual"' in choices_method
assert 'self.modeControl.selectedSegmentIndex' not in choices_method
assert "Proxy country is" in registry
assert "observedProxyCountry" in registry
assert "Live proxy exit is" in editor
assert "observedProxyCountry" in text("daemon/RBXProxyManager.m")
assert "supported by the synthetic model" in registry
assert "physical device model" not in validator
assert "physical runtime version" not in validator
assert "Identity is frozen after first use" in registry
assert "securityOnly" in registry and "securityOnly" in editor
assert "duplicates another container" in registry
assert "IMEI TAC does not match model" in validator
assert "WiFi and Bluetooth MAC addresses must differ" in validator
assert '@"identityResult"' in state
assert '@"identityCustomization"' in cloud
assert '@"security"' in cloud

# Raw stable identifiers must never be published in the world-readable launcher
# state document. Full values travel through a separate private Keychain draft.
state_source = state[state.index('NSDictionary *document = @{'):]
for secret_key in ("serialNumber", "udid", "imei1", "wifiMac", "btMac",
                   "platformUUID", "idfa", "idfv", "installId"):
    assert f'@"{secret_key}"' not in state_source

print("identity editor architecture tests passed")

assert 'Fill automatically' in editor and 'populateDraft:' in editor
assert 'saveIdentityEditorDraft:' in daemon
assert 'identityEditorDraftForRequestID:' in editor
assert 'self.identityLoaded' in editor
assert 'if (randomize && [state[@"locked"] boolValue])' in registry
assert 'self.simpleMode && !RBXIdentityReviewCanApply' not in editor
