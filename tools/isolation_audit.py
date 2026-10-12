#!/usr/bin/env python3
"""Host-side isolation invariant audit.

This cannot replace on-device packet/keychain tests. It prevents known fail-open
regressions and can compare profile JSON files for shared identity values.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
problems: list[str] = []


def text(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8", errors="replace")


def require(relative: str, needles: list[str]) -> None:
    content = text(relative)
    for needle in needles:
        if needle not in content:
            problems.append(f"{relative}: missing isolation invariant {needle!r}")


def reject(relative: str, needles: list[str]) -> None:
    content = text(relative)
    for needle in needles:
        if needle in content:
            problems.append(f"{relative}: forbidden fail-open pattern {needle!r}")

def require_order(relative: str, needles: list[str]) -> None:
    content = text(relative)
    cursor = -1
    for needle in needles:
        position = content.find(needle, cursor + 1)
        if position < 0:
            problems.append(f"{relative}: missing ordered state {needle!r}")
            return
        cursor = position


require(
    "tweak/Identity/RBXIdentityEngine.xm",
    ['dlsym(handle, "MGCopyAnswer")', "RBXMGVerifyAnswers",
     "RBXResolveMGProvider", "sMGContractReady"],
)
require_order(
    "daemon/main.m",
    ["closeTrafficWithReason", "killAllAndWait", "waitForSystemFirewallState",
     "rotateAndActivateProfile",
     "armTrafficForContainer", "launchRedditCloneForProfile",
     "waitForHookReadinessForProfile", "openTrafficForContainer"],
)
reject(
    "daemon/RBXProxyManager.m",
    ["provider.example", "rotation.example", "api/rotate"],
)
reject("tweak/Identity/RBXIdentityEngine.xm", ['dlsym(handle, "_MGCopyAnswer")'])
reject("tweak/RedditBox.xm",
       ["RBXInstallPathHooks(mgr)", "RBXInstallKeychainHooks(mgr)",
        "RBXInstallRequestAudit()"])
require(
    "daemon/RBXCloneManager.m",
    ["copyfile", "COPYFILE_CLONE", "CFBundleIdentifier",
     "keychain-access-groups", "RedditBoxProfile.json",
     "embedded.mobileprovision", "RBXMachOIsEncryptedAtPath",
     "PlugIns", "appinst", "_archiveTransactionRoot",
     "effective clone entitlements", "installd did not allocate",
     "recoverInterruptedTransactions", "verifyManagedInstallationForProfile"],
)
require("tweak/Container/RBXContainerManager.xm",
        ["SecTaskCopyValueForEntitlement", "RBXCloneKeychainProbe"])
require(
    "tweak/Network/RBXProxyHooks.xm",
    ["RBXHTTPProxySettings", "RBXHTTPProxyDelegate",
     "CFNetworkCopySystemProxySettings", "setHTTP3Enabled:"],
)
reject(
    "tweak/Network/RBXProxyHooks.xm",
    ['@"kCFProxyTypeKey"', "handled by NE layer", "BOOL enable = (bits & 2)"],
)
require(
    "tweak/Network/RBXSocketGuard.xm",
    ["replaced_connect", "replaced_connectx", "replaced_sendto",
     "replaced_sendmsg", "replaced_send", "replaced_write",
     "replaced_getaddrinfo", "RBXNetworkLeaseAllowsCurrentContainer", "EHOSTUNREACH"],
)
require(
    "tweak/Container/RBXWebStorageHooks.xm",
    ["WebKit storage uses clone OS sandbox",
     "blocked WKWebView load without active system-firewall lease",
     "prefersEphemeralWebBrowserSession"],
)
require(
    "tweak/Network/RBXRedditAPIHooks.xm",
    ["defaults/CFPreferences use clone OS sandbox"],
)
reject("tweak/Network/RBXRedditAPIHooks.xm",
       ["MSHookFunction((void *)CFPreferencesCopyAppValue"])
require(
    "tweak/AppAttest/RBXAppAttestHooks.xm",
    ["security.appAttest", "security.deviceCheck",
     "profile policy enforced", "if (handler) handler(nil, RBXAttestError())"],
)
require(
    "tweak/LeakDetection/RBXPushHooks.xm",
    ["push registration suppressed", "%hook PKPushRegistry", "push token callback dropped"],
)
require(
    "daemon/RBXProfileGenerator.m",
    ['profile[@"mgOverrides"] = RBXBuildMGOverrides(profile)'],
)
require(
    "daemon/main.m",
    ["closeTrafficWithReason", "killAllAndWait", "rotateAndActivateProfile",
     "armTrafficForContainer", "waitForHookReadinessForProfile",
     "openTrafficForContainer"],
)
reject("daemon/main.m", ["syncProxyAssignmentForContainer"])
require(
    "daemon/RBXProxyManager.m",
    ["RBX_ROTATION_URL", "RBX_ROTATION_AUTHORIZATION",
     "RBXRotationSecrets overrideForProfile",
     "ROTATION CALLED", "FRESH IP APPLIED", "rotation did not produce a fresh exit IP"],
)
require(
    "daemon/RBXNetworkGate.m",
    ["firewall-status.plist", "startDaemonHeartbeat",
     "waitForSystemFirewallState", "RBXWriteFirewallLease",
     "bundleIdentifier", 'isEqualToString:@"per-app"',
     "syncCurrentLeaseToProfile"],
)
require(
    "daemon/RBXProcessController.m",
    ["PROC_PIDLISTFDS", "PROX_FDTYPE_SOCKET", "KERNEL SOCKET TABLE CLEAN"],
)
require(
    "daemon/RBXCloudSync.m",
    ["_dataContainerForProfile", 'RBXCloudTarContainer(@"AppData"',
     "RBXCloudRestoreDataContents", "ensureAppCloneForContainer:newId"],
)
reject("daemon/RBXCloudSync.m", ["- (NSString *)_containersParent"])
require(
    "network-extension/PacketTunnel/PacketTunnelProvider.swift",
    ["NEAppProxyProvider", "handleNewFlow", "closeAllFlows", "TCPRelay",
     "readPolicy() == admitted", "providerBundleId"],
)
reject("network-extension/PacketTunnel/PacketTunnelProvider.swift",
       ["excludedRoutes", "startDroppingPackets", "includeAllNetworks"])
require(
    "tweak/Identity/RBXRuntimeHooks.xm",
    ["replaced_mach_absolute_time", "replaced_clock_gettime",
     "timing.syntheticBootEpoch", "RBXRuntimeHooksVerified"],
)
require(
    "tweak/Identity/RBXSensorHooks.xm",
    ["isAccelerometerAvailable", "isGyroAvailable",
     "isRelativeAltitudeAvailable", "maximumFramesPerSecond",
     "RBXSensorHooksVerified"],
)
require(
    "tweak/Identity/RBXGPUHooks.xm",
    ["replaced_registryID", "replaced_deviceName", "RBXGPUHooksVerified"],
)
require(
    "tweak/Network/RBXNetworkIdentityHooks.xm",
    ["replaced_getifaddrs", "replaced_CNCopyCurrentNetworkInfo",
     "replaced_nw_path_uses_interface_type",
     "fetchCurrentWithCompletionHandler", "RBXNetworkIdentityHooksVerified"],
)
require(
    "tweak/LeakDetection/RBXNotificationHooks.xm",
    ["addNotificationRequest", "getDeliveredNotifications",
     "registerForTaskWithIdentifier", "setMinimumBackgroundFetchInterval",
     "scheduledLocalNotifications"],
)
require(
    "tweak/Network/RBXSocketGuard.xm",
    ["replaced_socket", "replaced_bind", "replaced_listen",
     "replaced_gethostbyname", "replaced_DNSServiceGetAddrInfo",
     "replaced_res_query", "replaced_CFHostCreateWithName"],
)
require(
    "scripts/build-mac.sh",
    ["xcodegen generate", "xcodebuild archive", "RBX_FIREWALL_APP", "make -C"],
)

# Current phase-2/3 contract: these are source regression guards only.
require("shared/RBXHTTPProxy.m", ["FindProxyForURL", "PROXY", "NSURLCredentialPersistenceNone",
    "space.isProxy", "previousFailureCount", "RBXProxyHost(space.host)"])
reject("shared/RBXHTTPProxy.m", ["return 'DIRECT'", "NSURLConnection"])
require("daemon/RBXProcessController.m", ["watchRedditTerminationOnQueue", "_activeIdentity",
    "paths[identity[@\"pid\"]]", "bindingRevoked", "generation", "bootEpoch"])
require("daemon/RBXNetworkGate.m", ["expectedPID", "matchingPID", "RBXRequiredChecksPassed"])
require("daemon/RBXCloneManager.m", ["RBXBootstrapMatchesIdentity", "An IPA export is awaiting collection"])
require("tweak/Identity/RBXIOKitHooks.xm", ["RBXSanitizeIOKitTree", "depth > 16", "nested-physical"])
require("tweak/Container/RBXPasteboardHooks.xm", ["security.systemClipboard", "sOriginalGeneralPasteboard"])
require("shared/RBXProfileTransport.h", ["rotationAuth", "deviceToken", "passphrase"])


def nested(profile: dict, path: str):
    value = profile
    for part in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(part)
    return value


def audit_profiles(directory: Path) -> None:
    profiles: list[tuple[Path, dict]] = []
    for path in sorted(directory.glob("*.json")):
        if path.name == "catalog.json":
            continue
        try:
            profile = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            problems.append(f"{path}: invalid JSON: {exc}")
            continue
        profiles.append((path, profile))
        required = [
            "containerId", "serials.udid", "serials.serialNumber",
            "serials.platformUUID", "ids.idfv", "reddit.installId",
            "device.productType", "device.iosVersion", "device.locale",
            "device.timezone", "app.bundleIdentifier",
            "app.keychainAccessGroup", "app.bundlePath",
        ]
        for field in required:
            if not nested(profile, field):
                problems.append(f"{path.name}: missing {field}")
        if len(profile.get("mgOverrides", {})) < 10:
            problems.append(f"{path.name}: incomplete mgOverrides")

    unique_fields = [
        "serials.udid", "serials.serialNumber", "serials.platformUUID",
        "ids.idfv", "reddit.installId", "reddit.externalInstallationId",
        "proxy.url",
    ]
    for index, (left_path, left) in enumerate(profiles):
        for right_path, right in profiles[index + 1 :]:
            for field in unique_fields:
                value = nested(left, field)
                if value and value == nested(right, field):
                    problems.append(
                        f"{left_path.name}/{right_path.name}: shared {field} (value redacted)"
                    )


parser = argparse.ArgumentParser()
parser.add_argument("--profiles-dir", type=Path)
args = parser.parse_args()
if args.profiles_dir:
    audit_profiles(args.profiles_dir)

print("ISOLATION SOURCE AUDIT FAILED" if problems else "ISOLATION SOURCE AUDIT PASSED (not runtime isolation proof)")
for problem in problems:
    print(f" - {problem}")
sys.exit(1 if problems else 0)
