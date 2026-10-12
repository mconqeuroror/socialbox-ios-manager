ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = socialbox-drain
socialbox-drain_FILES = main.m LBXDarwinDrainBackend.m LBXProcessDrain.m LBXManagedApplications.m ../../shared/RBXProcessIdentity.m
socialbox-drain_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -I../../shared -Wno-deprecated-declarations
socialbox-drain_FRAMEWORKS = Foundation
socialbox-drain_CODESIGN_FLAGS = -SProcessDrain.entitlements
socialbox-drain_INSTALL_PATH = /usr/libexec

# Uninjected family-switch image. No Substrate Filter. Shipping the dylib is
# not an installed manager hook and does not claim isolationVerified.
LIBRARY_NAME = LBXNativeFamilySwitch
LBXNativeFamilySwitch_FILES = \
  LBXNativeIsolationJournal.m \
  LBXNativeBrokerAuthority.m \
  LBXNativeControlStore.m \
  LBXNativeStorageInventory.m \
  LBXNativeStorageLayout.m \
  LBXNativeFamilyStorageLayout.m \
  LBXInstalledApplicationBinding.m \
  LBXNativeApplicationGate.m \
  LBXNativeFamilyApplicationGate.m \
  LBXNativeStorageFence.m \
  LBXNativeControlLayout.m \
  LBXNativeInstalledManagerPin.m \
  LBXNativeSwitchCoordinator.m \
  LBXNativeManagerBridge.m \
  LBXDarwinDrainBackend.m \
  LBXProcessDrain.m \
  LBXManagedApplications.m \
  ../../shared/RBXProcessIdentity.m
LBXNativeFamilySwitch_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -I../../shared -Wno-deprecated-declarations
LBXNativeFamilySwitch_FRAMEWORKS = Foundation
LBXNativeFamilySwitch_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/library.mk
