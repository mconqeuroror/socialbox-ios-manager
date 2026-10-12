include $(dir $(lastword $(MAKEFILE_LIST)))../build-scheme.mk
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = SocialBoxFacebook
SocialBoxFacebook_FILES = main.m
SocialBoxFacebook_FRAMEWORKS = UIKit Foundation
SocialBoxFacebook_CFLAGS = -fobjc-arc
SocialBoxFacebook_CODESIGN_FLAGS = -SEntry.entitlements
SocialBoxFacebook_INSTALL_PATH = /Applications
SocialBoxFacebook_BUNDLE_ID = com.socialbox.facebook.entry
include $(THEOS_MAKE_PATH)/application.mk
