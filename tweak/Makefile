include $(dir $(lastword $(MAKEFILE_LIST)))../build-scheme.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedditBox

RedditBox_FILES = RedditBox.xm \
	Container/RBXContainerManager.xm \
	Container/RBXPathHooks.xm \
	Container/RBXKeychainHooks.xm \
	Container/RBXFacebookStorageHooks.xm \
	Container/RBXWebStorageHooks.xm \
	Container/RBXPasteboardHooks.xm \
	Identity/RBXIdentityEngine.xm \
	Identity/RBXAppleIdentifierHooks.xm \
	Identity/RBXDeviceHooks.xm \
	Identity/RBXSysctlHooks.xm \
	Identity/RBXIOKitHooks.xm \
	Identity/RBXLocaleHooks.xm \
	Identity/RBXTimezoneHooks.xm \
	Identity/RBXLocationHooks.xm \
	Identity/RBXBatteryHooks.xm \
	Identity/RBXTelephonyHooks.xm \
	Identity/RBXRuntimeHooks.xm \
	Identity/RBXSensorHooks.xm \
	Identity/RBXGPUHooks.xm \
	Network/RBXProxyHooks.xm \
	Network/RBXSocketGuard.xm \
	Network/RBXNetworkIdentityHooks.xm \
	JailbreakHiding/RBXJailbreakHider.xm \
	Common/RBXProfile.m \
	Common/RBXExceptionPortGuard.mm \
	AppAttest/RBXAppAttestHooks.xm \
	LeakDetection/RBXIsolationSentinel.m \
  LeakDetection/RBXPushHooks.xm \
	LeakDetection/RBXRequestAudit.xm \
	LeakDetection/RBXNotificationHooks.xm \
	Network/RBXRedditAPIHooks.xm \
	Network/RBXFacebookUserAgentHooks.xm \
	../shared/RBXMGOverrides.m ../shared/RBXHTTPProxy.m

RedditBox_CFLAGS = -fobjc-arc -ICommon -IContainer -IIdentity -INetwork -IJailbreakHiding -IAppAttest -ILeakDetection -I../shared
RedditBox_FRAMEWORKS = UIKit CoreTelephony CoreMotion QuartzCore Metal UserNotifications BackgroundTasks SystemConfiguration Network NetworkExtension AdSupport AppTrackingTransparency CoreLocation Security IOKit DeviceCheck CFNetwork PushKit WebKit AuthenticationServices
RedditBox_LIBRARIES = MobileGestalt

include $(THEOS_MAKE_PATH)/tweak.mk
