include $(dir $(lastword $(MAKEFILE_LIST)))../build-scheme.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = RedditBoxPrefs
RedditBoxPrefs_FILES = RBXRootListController.m
RedditBoxPrefs_INSTALL_PATH = /Library/PreferenceBundles
RedditBoxPrefs_CFLAGS = -fobjc-arc -I../shared
RedditBoxPrefs_FRAMEWORKS = UIKit Foundation Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences; cp RedditBoxPrefs.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/RedditBoxPrefs.plist$(ECHO_END)
