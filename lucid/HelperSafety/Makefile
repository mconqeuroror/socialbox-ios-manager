ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = LBXHelperSafety LBXAppSwitchSafety
LBXHelperSafety_FILES = LBXHelperSafety.m LBXDrainClient.m LBXDrainProtocol.m ../Switching/LBXManagedApplications.m
LBXHelperSafety_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations
LBXHelperSafety_FRAMEWORKS = Foundation
LBXHelperSafety_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

LBXAppSwitchSafety_FILES = LBXAppSwitchSafety.m LBXDrainClient.m LBXDrainProtocol.m LBXGlobalMetadata.m LBXGlobalMetadataHook.m ../Switching/LBXManagedApplications.m
LBXAppSwitchSafety_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations
LBXAppSwitchSafety_FRAMEWORKS = Foundation
LBXAppSwitchSafety_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

TOOL_NAME = socialbox-drain-service
socialbox-drain-service_FILES = Service.m LBXCallerFile.m LBXDrainProtocol.m ../Switching/LBXManagedApplications.m ../Switching/LBXProcessDrain.m ../Switching/LBXDarwinDrainBackend.m ../../shared/RBXProcessIdentity.m
socialbox-drain-service_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations
socialbox-drain-service_FRAMEWORKS = Foundation
socialbox-drain-service_CODESIGN_FLAGS = -S../Switching/ProcessDrain.entitlements
socialbox-drain-service_INSTALL_PATH = /usr/libexec
include $(THEOS_MAKE_PATH)/library.mk
include $(THEOS_MAKE_PATH)/tool.mk
