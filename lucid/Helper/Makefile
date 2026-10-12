ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TOOL_NAME = SocialBoxHelper
SocialBoxHelper_FILES = \
	main.m \
	LBXHelperService.m \
	LBXHelperAdmission.m \
	LBXHelperPaths.m \
	LBXHelperKeychain.m \
	LBXHelperSwap.m \
	LBXHelperStorage.m \
	LBXHelperLocation.m \
	../HelperSafety/LBXDrainClient.m \
	../HelperSafety/LBXDrainProtocol.m \
	../HelperSafety/LBXCallerFile.m \
	../Switching/LBXManagedApplications.m \
	../Switching/LBXProcessDrain.m \
	../Switching/LBXDarwinDrainBackend.m \
	../../shared/RBXProcessIdentity.m
SocialBoxHelper_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations
SocialBoxHelper_FRAMEWORKS = Foundation Security CoreLocation
SocialBoxHelper_CODESIGN_FLAGS = -SSocialBoxHelper.entitlements
SocialBoxHelper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
