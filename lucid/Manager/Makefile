ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SocialBox
SocialBox_FILES = \
	main.m \
	SBAppDelegate.m \
	SBContainersViewController.m \
	SBProxyViewController.m \
	SBProxyStore.m \
	SBLocationViewController.m \
	SBLocationStore.m \
	SBLocationSimulator.m \
	SBSlippyMapView.m \
	SBManagerText.m \
	../Presentation/SBDesign.m \
	../HelperClient/LBXHelperClient.m \
	../HelperClient/LBXContainerStore.m
SocialBox_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -I../Presentation
SocialBox_FRAMEWORKS = UIKit Foundation CoreGraphics CoreLocation QuartzCore
SocialBox_CODESIGN_FLAGS = -SSocialBox.entitlements
SocialBox_INSTALL_PATH = /Applications
SocialBox_BUNDLE_ID = com.socialbox.app

include $(THEOS_MAKE_PATH)/application.mk
