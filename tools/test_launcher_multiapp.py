#!/usr/bin/env python3
"""Architecture boundaries not exercised by Foundation-only app-scope fixtures."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
delegate = (ROOT / "launcher/RBXLauncherAppDelegate.m").read_text()
settings = (ROOT / "launcher/RBXSettingsViewController.m").read_text()

# An inactive app has no container execution controls. Source/diagnostic setup
# is an explicit action bound to the selected descriptor and guarded by unlock.
placeholder = delegate.split("- (UIViewController *)placeholderForDescriptor:", 1)[1].split("- (void)openSelectedAppSetup", 1)[0]
for forbidden in ("RBXLauncherIPC", "RBXSettingsViewController", "RBXLauncherViewController", "RBXSimpleWizard", "NSUserDefaults"):
    assert forbidden not in placeholder, forbidden
assert "RBXAppSetupStatus(nil, descriptor)" in placeholder
assert "socialbox.source-status" in placeholder and "socialbox.execution-status" in placeholder
assert "socialbox.network-status" in placeholder
assert "Source setup" in placeholder and "openSelectedAppSetup" in placeholder
setup = delegate.split("- (void)openSelectedAppSetup", 1)[1].split("- (UIViewController *)workspaceForDescriptor:", 1)[0]
assert '[self.containers workspaceUnlocked]' in setup and '[self hasPresentedController]' in setup
assert 'initWithAppType:descriptor[@"appType"] proxyMode:NO' in setup
assert "self.descriptors = RBXRegisteredAppDescriptors()" in delegate
assert "RBXAppScopeMaySelect" in delegate and "[self.containers workspaceUnlocked]" in delegate
assert "[self hasPresentedController]" in delegate
# Runnable apps share the source-owned three-section factory. Stable destination
# tags preserve routing; passcode and nested navigation still use UITabBarController.
assert '@[@"Containers",@"Connection",@"Settings"]' in delegate
assert "selector.redditWorkspace = tabs" in delegate
assert "RBXBuildWorkspaceTabs(self.containers,@\"reddit\",self)" in delegate
assert "RBXBuildWorkspaceTabs(containers,appType,self.redditWorkspace.delegate)" in delegate
assert "viewController == tabBarController.viewControllers.firstObject || [self.containers workspaceUnlocked]" in delegate
assert "[previous.view removeFromSuperview]" in delegate
assert "[previous removeFromParentViewController]" in delegate

# Every existing workspace consumer scopes container and operation publication.
for name in ("RBXLauncherViewController", "RBXSettingsViewController", "RBXSimpleWizardViewController",
             "RBXProxiesViewController", "RBXIsolationViewController", "RBXDiagnosticsViewController"):
    source = (ROOT / "launcher" / f"{name}.m").read_text()
    assert "RBXAppScopedLauncherState(" in source, name

# Source access validation is unchanged; app metadata is selected before any
# copy and bound to the asynchronous operation, not read from a global selector.
stage = settings.split("static NSString *RBXStageSourceIPA", 1)[1].split("@interface", 1)[0]
assert stage.index("RBXAppDescriptorIsRegistered") < stage.index("createDirectoryAtPath")
assert 'descriptor[@"sourceInboxPath"]' in stage
for primitive in ("O_RDONLY | O_NOFOLLOW", "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW", "S_ISREG", "0600", "0700", "fsync"):
    assert primitive in stage
assert '[self importSourceForAppType:self.appDescriptor[@"appType"]]' in settings
assert 'initWithAppType:@"reddit"' in settings
assert '![descriptor[@"appType"] isEqual:self.appDescriptor[@"appType"]]' in settings
assert "RBXStageSourceIPA(readURL, descriptor, &copyError)" in settings
assert 'values:@{@"ipaPath": stagedPath, @"appType":descriptor[@"appType"]}' in settings
assert "RBXAppSourceImportRequestKey(descriptor)" in settings
print("launcher multi-app architecture tests passed")

# App-bound controllers retain legacy entry points while every daemon request
# uses the immutable descriptor. Shared proxy/license/network stores remain global.
for name in ("RBXLauncherViewController", "RBXSettingsViewController", "RBXSimpleWizardViewController",
             "RBXIdentityViewController", "RBXProxiesViewController", "RBXIsolationViewController", "RBXDiagnosticsViewController"):
    source = (ROOT / "launcher" / f"{name}.m").read_text()
    assert 'appType:self.appDescriptor[@"appType"]' in source, name
    assert 'RBXAppScopedPreferenceKey(' in source, name
assert 'RBXAppSourceReadinessError(self.launcherState, self.appDescriptor)' in (ROOT / "launcher/RBXLauncherViewController.m").read_text()
assert 'RBXAppSourceReadinessError(self.state, self.appDescriptor)' in (ROOT / "launcher/RBXSimpleWizardViewController.m").read_text()
assert 'self.workspaces[appType] = cached' in delegate and 'if (![descriptor[@"runnable"] boolValue])' in delegate
assert 'if ([self.appDescriptor[@"appType"] isEqual:@"reddit"]) [actions addAction:[UIAlertAction actionWithTitle:@"Check account status"' in (ROOT / "launcher/RBXLauncherViewController.m").read_text()

license_screen = (ROOT / "launcher/RBXLicenseViewController.m").read_text()
assert 'initWithLicenseState:licenseState appType:@"reddit"' in license_screen
assert 'initWithAppType:self.appDescriptor[@"appType"] proxyMode:NO' in license_screen
assert 'initWithAppType:self.appDescriptor[@"appType"]' in license_screen
account_route = settings.split('- (void)openAccount {', 1)[1].split('\n}', 1)[0]
assert '[self performSetupAction:@"license"];' in account_route
assert 'RBXAccountStatusViewController' not in account_route
assert 'initWithLicenseState:nil appType:self.appDescriptor[@"appType"]' in settings
source_setup = settings.split('- (void)buildSourceSetup {', 1)[1].split('- (void)dealloc', 1)[0]
assert 'action:@selector(importSource)' in source_setup
for forbidden in ('openDiagnostics', 'shareManagedSetup', 'createContainer', 'configureCloud', 'submitAction:', 'sendActionReturningRequestId:'):
    assert forbidden not in source_setup, forbidden

# The source-removal daemon branch is still the audited Reddit lifecycle.
# A future active FB descriptor must not reveal a button that removes Reddit.
assert 'if ([self.appDescriptor[@"appType"] isEqual:@"reddit"]) [sheet addAction:[UIAlertAction actionWithTitle:[self appText:@"Hide source Reddit app"]' in (ROOT / "launcher/RBXLauncherViewController.m").read_text()
