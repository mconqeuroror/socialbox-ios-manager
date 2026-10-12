include $(dir $(lastword $(MAKEFILE_LIST)))../build-scheme.mk

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = redditboxd redditbox-keychain-cleaner

redditboxd_FILES = main.m RBXContainerRegistry.m RBXReplacement.m RBXProfileIO.m RBXDataMigration.m RBXOperationContext.m RBXBoundedProcess.m RBXCloneManager.m RBXLauncherState.m RBXSentinelController.m RBXDiagnostics.m RBXProfileGenerator.m RBXConsistencyValidator.m RBXDeviceCatalog.m RBXProcessController.m RBXAppProcessCoordinator.m RBXStorageAccess.m RBXProxyManager.m RBXNetworkGate.m RBXAppVersionMonitor.m RBXCentralStore.m RBXHealthChecker.m RBXLeakMonitor.m RBXFingerprintRegistry.m RBXABTestFramework.m RBXCloudSync.m RBXLicenseGuard.m RBXLicenseToken.m RBXRotationSecrets.m RBXBackupSnapshot.m ../shared/RBXMGOverrides.m ../shared/RBXSecureConfig.m ../shared/RBXHTTPProxy.m ../shared/RBXRequestQueue.m ../shared/RBXProcessIdentity.m
redditboxd_CFLAGS = -Wno-error=nullability-completeness -fobjc-arc -I../shared -DRBX_DAEMON_OPERATION_CONTEXT=1
ifneq ($(strip $(RBX_LICENSE_PIN_HEADER)),)
redditboxd_CFLAGS += -include "$(RBX_LICENSE_PIN_HEADER)"
endif
redditboxd_FRAMEWORKS = Foundation Security CFNetwork
# iOS supplies libarchive; its headers may come from the SDK or Homebrew.
LIBARCHIVE_INCLUDE ?= $(shell pkg-config --variable=includedir libarchive 2>/dev/null)
ifeq ($(strip $(LIBARCHIVE_INCLUDE)),)
LIBARCHIVE_INCLUDE = $(shell brew --prefix libarchive 2>/dev/null)/include
endif
redditboxd_CFLAGS += -I$(LIBARCHIVE_INCLUDE)
redditboxd_LIBRARIES = archive sqlite3
redditboxd_CODESIGN_FLAGS = -Sredditboxd.entitlements
redditboxd_INSTALL_PATH = /usr/bin

redditbox-keychain-cleaner_FILES = RBXKeychainCleaner.m
redditbox-keychain-cleaner_CFLAGS = -fobjc-arc
redditbox-keychain-cleaner_FRAMEWORKS = Foundation Security
# The shipped template cannot erase a clone group. The daemon signs a private
# copy with exactly one validated clone identity before explicit deletion.
redditbox-keychain-cleaner_CODESIGN_FLAGS = -SRBXKeychainCleaner.entitlements
redditbox-keychain-cleaner_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/LaunchDaemons; cp "$(RBX_VARIANT_INPUTS)/com.redditbox.daemon.plist" $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.redditbox.daemon.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/usr/share/redditbox; cp ../profiles/catalog.json $(THEOS_STAGING_DIR)/usr/share/redditbox/catalog.json$(ECHO_END)
	$(ECHO_NOTHING)cp ../tools/isolation_audit.py $(THEOS_STAGING_DIR)/usr/share/redditbox/isolation_audit.py; cp ../scripts/smoke-log-order.awk $(THEOS_STAGING_DIR)/usr/share/redditbox/smoke-log-order.awk; cp "$(RBX_VARIANT_INPUTS)/on-device-smoke.sh" $(THEOS_STAGING_DIR)/usr/share/redditbox/on-device-smoke.sh; chmod 755 $(THEOS_STAGING_DIR)/usr/share/redditbox/on-device-smoke.sh$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/usr/bin; cp "$(RBX_VARIANT_INPUTS)/provision-profile.sh" $(THEOS_STAGING_DIR)/usr/bin/redditbox-profile; chmod 755 $(THEOS_STAGING_DIR)/usr/bin/redditbox-profile$(ECHO_END)
	$(ECHO_NOTHING)cp com.redditbox.rotation.example.plist $(THEOS_STAGING_DIR)/usr/share/redditbox/com.redditbox.rotation.example.plist$(ECHO_END)
