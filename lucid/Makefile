ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LBXPresentation
LBXPresentation_FILES = $(wildcard Presentation/*.m) $(wildcard Diagnostics/*.m) $(wildcard ProxyInput/*.m) ../shared/RBXHTTPProxy.m Authorization/LBXLicenseClient.m Authorization/LBXLicenseIPC.m Authorization/LBXLicensePeer.m HelperSafety/LBXCallerFile.m Containers/LBXContainerClient.m Containers/LBXContainerIPC.m Containers/LBXContainerConfiguration.m Containers/LBXContainerPendingMutation.m Containers/LBXContainerMutationCoordinator.m Containers/LBXContainerMutationClient.m Containers/LBXContainerMutationIPC.m Containers/LBXContainerRootMutationCoordinator.m
LBXPresentation_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -IPresentation -IDiagnostics -IProxyInput
LBXPresentation_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics CFNetwork MapKit
LBXPresentation_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
