ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SocialBoxContainermanagerd SocialBoxCfPrefsd SocialBoxAppKeychain SocialBoxLocation

_INJECT_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations

SocialBoxContainermanagerd_FILES = SocialBoxContainermanagerd.m LBXInjectCommon.m
SocialBoxContainermanagerd_CFLAGS = $(_INJECT_CFLAGS)
SocialBoxContainermanagerd_FRAMEWORKS = Foundation CoreFoundation
SocialBoxContainermanagerd_LIBRARIES = substrate

SocialBoxCfPrefsd_FILES = SocialBoxCfPrefsd.m LBXInjectCommon.m
SocialBoxCfPrefsd_CFLAGS = $(_INJECT_CFLAGS)
SocialBoxCfPrefsd_FRAMEWORKS = Foundation CoreFoundation
SocialBoxCfPrefsd_LIBRARIES = substrate

# Client-side keychain partition inside IG/FB only. Does not load into securityd.
SocialBoxAppKeychain_FILES = SocialBoxAppKeychain.m LBXInjectCommon.m
SocialBoxAppKeychain_CFLAGS = $(_INJECT_CFLAGS)
SocialBoxAppKeychain_FRAMEWORKS = Foundation CoreFoundation Security
SocialBoxAppKeychain_LIBRARIES = substrate

# Device-wide GPS remap. Helper JSON + Darwin notify control start/stop.
SocialBoxLocation_FILES = SocialBoxLocation.m
SocialBoxLocation_CFLAGS = $(_INJECT_CFLAGS)
SocialBoxLocation_FRAMEWORKS = Foundation CoreLocation
SocialBoxLocation_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
