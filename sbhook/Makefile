include $(dir $(lastword $(MAKEFILE_LIST)))../build-scheme.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedditBoxSB

RedditBoxSB_FILES = RedditBoxSB.xm

RedditBoxSB_CFLAGS = -fobjc-arc
RedditBoxSB_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
