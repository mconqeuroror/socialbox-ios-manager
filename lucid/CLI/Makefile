ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TOOL_NAME = SocialBoxCLI
SocialBoxCLI_FILES = \
	main.m \
	../HelperClient/LBXHelperClient.m \
	../HelperClient/LBXContainerStore.m
SocialBoxCLI_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror
SocialBoxCLI_FRAMEWORKS = Foundation
SocialBoxCLI_CODESIGN_FLAGS = -SSocialBoxCLI.entitlements
SocialBoxCLI_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
