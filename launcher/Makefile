include $(dir $(lastword $(MAKEFILE_LIST)))../build-scheme.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RedditBox
RedditBox_FILES = main.m RBXLauncherAppDelegate.m RBXWorkspaceNavigationController.m RBXLauncherViewController.m RBXLauncherIPC.m RBXSettingsViewController.m RBXProxiesViewController.m RBXCloudVaultViewController.m RBXIsolationViewController.m ../shared/RBXProxyLibrary.m RBXDiagnosticsViewController.m RBXIdentityViewController.m RBXCatalogPickerViewController.m RBXLocationPickerViewController.m RBXSimpleWizardViewController.m RBXMDMExporter.m RBXPasscodeStore.m RBXAccountStatusViewController.m RBXLicenseViewController.m ../shared/RBXSecureConfig.m ../shared/RBXHTTPProxy.m ../shared/RBXRequestQueue.m ../shared/RBXAcceptanceChecks.m
RedditBox_FRAMEWORKS = UIKit Foundation CFNetwork Security WebKit MapKit CoreLocation
RedditBox_CFLAGS = -Wno-error=nullability-completeness -fobjc-arc -I../shared
RedditBox_CODESIGN_FLAGS = -SRedditBox.entitlements
RedditBox_INSTALL_PATH = /Applications
RedditBox_BUNDLE_ID = com.redditbox.launcher

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -p $(THEOS_PACKAGE_INSTALL_PREFIX)/Applications/RedditBox.app"
