#!/usr/bin/env python3
"""Static consistency check for the RedditBox repo (host-side, no toolchain needed).

Verifies:
 1. Every source file listed in each Makefile exists.
 2. Every local #import resolves (same dir, or tweak/Common for -ICommon).
 3. All JSON/plist files parse.
 4. Path constants shared between daemon and tweak match.
 5. Logos %hook/%end balance in .xm files.
"""
import glob
import json
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
problems = []

# Invalid text encoding can corrupt UI strings while compiler syntax still passes.
text_extensions = {".m", ".h", ".xm", ".swift", ".ts", ".tsx", ".py", ".sh", ".md", ".json", ".yml"}
for source_root in ("daemon", "launcher", "entry", "shared", "tweak", "network-extension", "cloud/src", "tools", "scripts", "docs", "profiles", "prefs"):
    for directory, _, names in os.walk(os.path.join(ROOT, source_root)):
        for name in names:
            if os.path.splitext(name)[1] not in text_extensions:
                continue
            path = os.path.join(directory, name)
            try:
                with open(path, encoding="utf-8") as source:
                    contents = source.read()
                if os.path.splitext(name)[1] in {".m", ".h", ".xm"} and "NSJSON" + "PrettyPrinted" in contents:
                    problems.append(f"{os.path.relpath(path, ROOT)}: invalid JSON writing option")
            except UnicodeDecodeError:
                problems.append(f"{os.path.relpath(path, ROOT)}: invalid UTF-8 text")

# --- 1. Makefile FILES exist ---------------------------------------------------
makefile_files = {
    "tweak/Makefile": "RedditBox_FILES = RedditBox.xm Container/RBXContainerManager.xm Container/RBXPathHooks.xm Container/RBXKeychainHooks.xm Container/RBXFacebookStorageHooks.xm Container/RBXWebStorageHooks.xm Container/RBXPasteboardHooks.xm Identity/RBXIdentityEngine.xm Identity/RBXAppleIdentifierHooks.xm Identity/RBXDeviceHooks.xm Identity/RBXSysctlHooks.xm Identity/RBXIOKitHooks.xm Identity/RBXLocaleHooks.xm Identity/RBXTimezoneHooks.xm Identity/RBXLocationHooks.xm Identity/RBXBatteryHooks.xm Identity/RBXTelephonyHooks.xm Identity/RBXRuntimeHooks.xm Identity/RBXSensorHooks.xm Identity/RBXGPUHooks.xm Network/RBXProxyHooks.xm Network/RBXSocketGuard.xm Network/RBXNetworkIdentityHooks.xm JailbreakHiding/RBXJailbreakHider.xm Common/RBXProfile.m Common/RBXExceptionPortGuard.mm AppAttest/RBXAppAttestHooks.xm LeakDetection/RBXIsolationSentinel.m LeakDetection/RBXPushHooks.xm LeakDetection/RBXRequestAudit.xm LeakDetection/RBXNotificationHooks.xm Network/RBXRedditAPIHooks.xm Network/RBXFacebookUserAgentHooks.xm ../shared/RBXMGOverrides.m ../shared/RBXHTTPProxy.m",
    "daemon/Makefile": "redditboxd_FILES = main.m RBXContainerRegistry.m RBXReplacement.m RBXProfileIO.m RBXDataMigration.m RBXOperationContext.m RBXBoundedProcess.m RBXCloneManager.m RBXLauncherState.m RBXSentinelController.m RBXDiagnostics.m RBXProfileGenerator.m RBXConsistencyValidator.m RBXDeviceCatalog.m RBXProcessController.m RBXAppProcessCoordinator.m RBXStorageAccess.m RBXProxyManager.m RBXNetworkGate.m RBXAppVersionMonitor.m RBXCentralStore.m RBXHealthChecker.m RBXLeakMonitor.m RBXFingerprintRegistry.m RBXABTestFramework.m RBXCloudSync.m RBXLicenseGuard.m RBXLicenseToken.m RBXRotationSecrets.m RBXBackupSnapshot.m ../shared/RBXMGOverrides.m ../shared/RBXSecureConfig.m ../shared/RBXHTTPProxy.m ../shared/RBXRequestQueue.m ../shared/RBXProcessIdentity.m",
    "launcher/Makefile": "RedditBox_FILES = main.m RBXLauncherAppDelegate.m RBXWorkspaceNavigationController.m RBXLauncherViewController.m RBXLauncherIPC.m RBXSettingsViewController.m RBXProxiesViewController.m RBXCloudVaultViewController.m RBXIsolationViewController.m ../shared/RBXProxyLibrary.m RBXDiagnosticsViewController.m RBXIdentityViewController.m RBXCatalogPickerViewController.m RBXLocationPickerViewController.m RBXSimpleWizardViewController.m RBXMDMExporter.m RBXPasscodeStore.m RBXAccountStatusViewController.m RBXLicenseViewController.m ../shared/RBXSecureConfig.m ../shared/RBXHTTPProxy.m ../shared/RBXRequestQueue.m ../shared/RBXAcceptanceChecks.m",
    "prefs/Makefile": "RedditBoxPrefs_FILES = RBXRootListController.m",
}
for mk_path, declared in makefile_files.items():
    makefile = os.path.join(ROOT, mk_path)
    if not os.path.exists(makefile):
        problems.append(f"{mk_path}: Makefile missing")
        continue
    content = open(makefile).read()
    for entry in declared.split():
        if entry.endswith(".xm") or entry.endswith(".m"):
            p = os.path.join(ROOT, os.path.dirname(mk_path), entry)
            if not os.path.exists(p):
                problems.append(f"{mk_path}: missing source {entry}")
    # verify Makefile matches the declared list (backslash continuation)
    match = re.search(r"_FILES\s*=\s*(.*?)(?:\n\n|\n[A-Za-z-]+_)", content, re.S)
    if match:
        listed = " ".join(match.group(1).replace("\\\n", " ").replace("\\", " ").split())
        expected = " ".join(declared.split()[2:])
        if listed != expected:
            problems.append(f"{mk_path}: _FILES drift: got [{listed}]")

# The daemon subproject also ships the inert, explicitly signed cleanup helper.
daemon_makefile = open(os.path.join(ROOT, "daemon/Makefile")).read()
cleaner_files = re.search(r"^redditbox-keychain-cleaner_FILES\s*=\s*([^\n]+)",
                          daemon_makefile, re.M)
if not cleaner_files or cleaner_files.group(1).strip() != "RBXKeychainCleaner.m":
    problems.append("daemon/Makefile: keychain cleaner source declaration drift")
if not os.path.isfile(os.path.join(ROOT, "daemon/RBXKeychainCleaner.m")):
    problems.append("daemon/Makefile: missing keychain cleaner source")

# --- 2. local imports resolve ---------------------------------------------------
srcs = []
for pattern in ["tweak/**/*.xm", "tweak/**/*.h", "tweak/**/*.m", "daemon/*.m", "daemon/*.h", "prefs/*.m", "prefs/*.h", "launcher/*.m", "launcher/*.h", "shared/*.m", "shared/*.h"]:
    srcs += glob.glob(os.path.join(ROOT, pattern), recursive=True)

for src in srcs:
    rel = os.path.relpath(src, ROOT)
    content = open(src, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r'#import\s+"([^"]+)"', content):
        imp = m.group(1)
        # include candidates: same dir as src + every -I<dir> declared in the tweak Makefile
        subdir = os.path.relpath(os.path.dirname(src), ROOT)
        inc_dirs = ["."]
        if subdir.startswith("tweak"):
            mk = open(os.path.join(ROOT, "tweak/Makefile")).read()
            for im in re.finditer(r"-I([^\s]+)", mk):
                inc_dirs.append(os.path.join("tweak", im.group(1)))
        else:
            mk_path = os.path.join(ROOT, subdir.split(os.sep)[0], "Makefile")
            if os.path.exists(mk_path):
                mk = open(mk_path).read()
                for im in re.finditer(r"-I([^\s]+)", mk):
                    inc_dirs.append(os.path.normpath(os.path.join(subdir.split(os.sep)[0], im.group(1))))
        cands = [os.path.join(ROOT, os.path.dirname(src), imp)] + [
            os.path.join(ROOT, d, imp) for d in inc_dirs
        ]
        if not any(os.path.exists(c) for c in cands):
            problems.append(f"{rel}: unresolved local import {imp}")

    # --- 5. Logos balance (strip comments first) ---
    if src.endswith(".xm"):
        stripped = re.sub(r"//[^\n]*", "", content)
        hooks = len(re.findall(r"%hook\s", stripped))
        groups = len(re.findall(r"%group\s", stripped))
        ends = len(re.findall(r"%end\s*", stripped))
        if hooks + groups != ends:
            problems.append(
                f"{rel}: %hook({hooks}) + %group({groups}) / %end({ends}) mismatch"
            )

# --- 3. JSON/plist parse --------------------------------------------------------
for j in ["profiles/catalog.json", "cloud/src/config/app-registry.json"]:
    try:
        json.load(open(os.path.join(ROOT, j)))
    except Exception as e:
        problems.append(f"{j}: {e}")
for p in ["prefs/RedditBoxPrefs.plist", "daemon/com.redditbox.daemon.plist",
          "launcher/Resources/Info.plist", "launcher/RedditBox.entitlements",
          "daemon/redditboxd.entitlements", "daemon/RBXKeychainCleaner.entitlements"]:
    try:
        plistlib.load(open(os.path.join(ROOT, p), "rb"))
    except Exception as e:
        problems.append(f"{p}: {e}")
# Substrate filter plists are OpenStep-style; verify structure textually
for p in ["tweak/RedditBox.plist"]:
    txt = open(os.path.join(ROOT, p)).read()
    if "Filter" not in txt or ("Bundles" not in txt and "Executables" not in txt):
        problems.append(f"{p}: not a Substrate filter plist")

# The same canonical descriptor data is consumed by the native and cloud sides.
import subprocess
if subprocess.run([sys.executable, os.path.join(ROOT, "tools/generate_app_registry.py"), "--check"],
                  stdout=subprocess.DEVNULL).returncode:
    problems.append("app registry generated native data is stale")

# --- 4. shared path constants ---------------------------------------------------
profiles_dir = "/var/mobile/Library/Preferences/com.redditbox.profiles"
binding = "/var/mobile/Library/Preferences/com.redditbox.activeContainer"
request_queue = "/var/mobile/Library/RedditBox/IPC"

def grep(path, needle):
    return needle in open(os.path.join(ROOT, path), encoding="utf-8", errors="replace").read()

if not grep("daemon/RBXProcessController.m", binding):
    problems.append("RBXProcessController.m: binding file constant drift")
if not grep("shared/RBXRequestQueue.m", request_queue):
    problems.append("RBXRequestQueue.m: request queue root drift")
if not grep("daemon/main.m", "RBXRequestQueue"):
    problems.append("daemon/main.m: shared request queue transport missing")
if not grep("launcher/RBXLauncherIPC.m", "RBXRequestQueue"):
    problems.append("launcher: shared request queue transport missing")
if not grep("daemon/RBXContainerRegistry.m", profiles_dir):
    problems.append("RBXContainerRegistry.m: profiles dir constant drift")
if not grep("daemon/RBXProfileIO.m", profiles_dir):
    problems.append("profile loader: profiles dir constant drift")

# catalog staging path matches daemon read path
if not grep("daemon/RBXDeviceCatalog.m", 'RBXInstalledPath(@"/usr/share/redditbox/catalog.json")'):
    problems.append("RBXDeviceCatalog.m: catalog path drift")

proxy_pool = "/var/mobile/Library/Preferences/com.redditbox.proxies.plist"
if not grep("daemon/RBXProxyManager.m", proxy_pool):
    problems.append("RBXProxyManager.m: proxy pool path drift")
if not grep("daemon/RBXCloudSync.m", "[RBXProxyManager readPool:"):
    problems.append("RBXCloudSync.m: checked shared proxy pool reader missing")

if not grep("daemon/RBXProxyManager.m", "com.redditbox.rotation.plist"):
    problems.append("RBXProxyManager.m: rotation config path missing")
if not grep("daemon/RBXNetworkGate.m", "com.redditbox.network-lease.plist"):
    problems.append("RBXNetworkGate.m: network lease path missing")

# Clone architecture must use OS app containers/keychain entitlements and must
# not install the legacy storage/keychain virtualizers.
if not grep("daemon/RBXCloneManager.m", "keychain-access-groups"):
    problems.append("RBXCloneManager.m: isolated keychain entitlement missing")
if not grep("daemon/RBXCloneManager.m", "RedditBoxProfile.json"):
    problems.append("RBXCloneManager.m: signed bootstrap profile missing")
if not grep("daemon/RBXCloneManager.m", 'info[@"SBAppTags"] = @[@"hidden"]'):
    problems.append("RBXCloneManager.m: hidden clone marker missing")
root_makefile = open(os.path.join(ROOT, "Makefile")).read()
if "sbhook" in re.search(r"SUBPROJECTS\s*=\s*([^\n]+)", root_makefile).group(1):
    problems.append("root Makefile: SpringBoard hook is still packaged")
if "launcher" not in root_makefile:
    problems.append("root Makefile: launcher is not packaged")
if grep("tweak/RedditBox.xm", "RBXInstallPathHooks(mgr)"):
    problems.append("RedditBox.xm: legacy path isolation is still installed")
if grep("tweak/RedditBox.xm", "RBXInstallKeychainHooks(mgr)"):
    problems.append("RedditBox.xm: legacy keychain isolation is still installed")
if not grep("tweak/Container/RBXContainerManager.xm", "RBXAppRuntimeProfileMatchesBundle(dict, actualBundle)") or not grep("shared/RBXAppRuntime.h", "RBXAppBundleIdentifier(descriptor, container)"):
    problems.append("RBXContainerManager.xm: clone bundle binding missing")

print("PROBLEMS:" if problems else "ALL CLEAN")
for p in problems:
    print(" -", p)
sys.exit(1 if problems else 0)
