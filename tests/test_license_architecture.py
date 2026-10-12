"""Portable cross-component contracts for signed device licensing.

The real Foundation/Security execution tests require macOS; this script checks
that production wiring continues to call those verified policy paths.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
guard = (root / "daemon/RBXLicenseGuard.m").read_text(encoding="utf-8")
token = (root / "daemon/RBXLicenseToken.m").read_text(encoding="utf-8")
main = (root / "daemon/main.m").read_text(encoding="utf-8")
pins = (root / "shared/RBXLicensePin.h").read_text(encoding="utf-8")

assert "SecKeyVerifySignature" in token and "kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256" in token
assert 'header[@"alg"] isEqual:@"RS256"' in token and 'header[@"kid"] isEqual:keyID' in token
for field in ("server", "deviceId", "deviceBinding", "keyFingerprint"):
    assert f'expected[@"{field}"]' in token
assert 'claims[@"nonce"] isEqual:nonce' in token
assert '+ 72 * 3600' in token
assert 'RBXTokenInteger(claims[@"v"])' in token
assert 'RBX_LICENSE_PUBLIC_KEY_DER_BASE64 ""' in pins
assert 'RBX_LICENSE_KEY_ID ""' in pins
assert 'SecItemCopyMatching' in guard and 'SecItemAdd' in guard
assert 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' in guard
assert '@"RBXBOXCFG.com.redditbox.daemon-control"' in guard
assert 'lastObservedAt' in guard and 'clock-error' in guard
assert 'RBX_LICENSE_STATE_PLIST' in guard and 'license-state.plist' in guard
assert 'O_EXCL | O_NOFOLLOW, 0600' in guard and 'fsync(descriptor)' in guard
assert 'rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation)' in guard
assert 'RBXLicenseWriteState' in guard and 'licenseLastOkAt' not in guard
assert 'json[@"valid"]' not in guard, "unsigned validation flags must never unlock"
assert 'killAllRedditProcesses' not in guard and 'dispatch_source_create' not in guard
assert 'completionHandler(nil)' in guard, "license redirects must be rejected before forwarding key bodies"
assert 'untrackTask:task' in guard and 'trackTask:task' in guard
assert 'acceptLicensePairing:pairing context:context' in guard
assert 'expiresAt' in guard and 'offlineGrace' in guard and 'retryAt' in guard
fast = guard.split('- (NSTimeInterval)trafficEntitlementExpiresAt {')[1].split('- (BOOL)trafficEntitlementValid')[0]
assert '_trafficDeadlineMonotonic' in fast and '_trafficWallDeadline' in fast
assert '_trafficLock' in fast and 'SecItem' not in fast and 'RBXLicenseReadState' not in fast
assert 'activateLicense' in main and 'validateLicense' in main
print('PASS signed token, device binding, isolated state, lifetime, grace and activation wiring contracts')
