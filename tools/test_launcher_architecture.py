#!/usr/bin/env python3
"""Host-side invariants for the managed RedditBox launcher."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


root_makefile = text("Makefile")
launcher = text("launcher/RBXLauncherViewController.m")
settings = text("launcher/RBXSettingsViewController.m")
diagnostics = text("launcher/RBXDiagnosticsViewController.m")
daemon = text("daemon/main.m")
clone = text("daemon/RBXCloneManager.m")
state = text("daemon/RBXLauncherState.m")
cloud_route = text("cloud/src/app/api/profiles/route.ts")

subprojects = next(
    line for line in root_makefile.splitlines() if line.startswith("SUBPROJECTS")
)
assert "launcher" in subprojects
assert "sbhook" not in subprojects

for action in ("createContainer", "launchContainer", "deleteContainer",
               "refreshLauncher", "openFirewall", "archiveSource",
               "exportCloneIPA"):
    assert f'@"{action}"' in launcher
assert "/usr/bin/open" not in launcher
assert "LSApplicationWorkspace" not in launcher
assert "com.redditbox.launchContainer" in launcher
assert "com.redditbox.launcherAction" in launcher

assert 'info[@"SBAppTags"] = @[@"hidden"]' in clone
assert 'info[@"RBXLauncherOnly"] = @YES' in clone
assert '[info[@"SBAppTags"] containsObject:@"hidden"]' in clone
assert "validateCloneForProfile" in daemon
assert daemon.index("validateCloneForProfile") < daemon.index("rotateAndActivateProfile")

assert "com.redditbox.launcher-state.plist" in state
for forbidden in ("rotationAuthSecret", "deviceToken", "proxyURL", "password"):
    assert forbidden not in state
assert "startPeriodicPublisherWithRegistry" in daemon
assert "syncProfileInventoryWithContext:" in daemon
# The first licensed Create must publish inventory before its success receipt,
# while an unavailable cloud preserves the created clone and offers Refresh.
create = daemon.split('if ([action isEqualToString:@"createContainer"]) {', 1)[1].split('\n        } else {', 1)[0]
assert create.index('forContainer:created local:YES') < create.index('syncProfileInventoryWithContext:')
assert create.index('syncProfileInventoryWithContext:') < create.index('created, YES, message')
assert 'Use Refresh before Open' in create
assert 'deleteContainer:' not in create
rotation_auth = text("daemon/RBXCloudSync.m").split('- (void)syncRotationAuthForContainer:', 2)[2]
assert 'cloudProfileBindings' in rotation_auth
assert 'Pairing is optional' not in settings and 'Cloud pairing is optional' not in settings
assert "SBAppTags: [hidden]" in text("network-extension/project.yml")
assert "archiveSourceAndRemoveVisibleApp" in daemon
assert 'self.appDescriptor[@"sourceCachePath"]' in clone
assert "/var/mobile/Library/RedditBox/Source/Reddit.app" in text("cloud/src/config/app-registry.json")
assert "com.redditbox.loginActivity" in daemon
assert "com.redditbox.loginActivity" in text("tweak/Network/RBXRedditAPIHooks.xm")
assert "RBXSecureConfig saveRotationConfiguration" in settings
assert '@"proxyURL"' not in text("launcher/RBXLauncherIPC.m")
assert "testConfiguration" in settings
assert "runDiagnostics" in diagnostics and "exportSupportLog" in diagnostics
assert "RBXBOXCFG.com.redditbox.config" in text("launcher/RedditBox.entitlements")
assert "RBXBOXCFG.com.redditbox.config" in text("daemon/redditboxd.entitlements")
proxy_manager = text("daemon/RBXProxyManager.m")
assert proxy_manager.index("RBXSecureConfig rotationConfiguration") < \
       proxy_manager.index("stat(kRotationConfigPath")
assert "syncLauncherConfigurationWithContext:" in daemon
assert "rotation-settings" in text("cloud/src/app/api/rotation-settings/route.ts")
assert "appVersionConfigurationChanged" in settings
assert "uicache -a" not in text("layout/DEBIAN/postinst")
assert "uicache -p /var/jb/Applications/RedditBox.app" in text("layout/DEBIAN/postinst")
assert "uicache -p /var/jb/Applications/RedditBoxFirewall.app" in text("layout/DEBIAN/postinst")
control = text("control")
for dependency in ("ldid", "ai.akemi.appinst (>= 2.1.1)", "uikittools (>= 2.1.6)", "zip",
                   "ai.akemi.appsyncunified"):
    assert dependency in control

assert "getDeviceFromRequest(req)" in cloud_route
assert "deviceId is required" in cloud_route
assert "nickname" in cloud_route and "country" in cloud_route

print("launcher architecture tests passed")
