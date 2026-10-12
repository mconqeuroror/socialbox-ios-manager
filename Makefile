include $(dir $(lastword $(MAKEFILE_LIST)))build-scheme.mk

# Keep legacy API/helper warnings visible during compatibility builds.
export ADDITIONAL_CFLAGS += -Wno-error=deprecated-declarations -Wno-error=unused-function -Wno-error=unused-variable

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = tweak daemon launcher prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	@test -f "$(RBX_RELEASE_METADATA)" || (echo "Release metadata is required; use scripts/build-mac.sh" && exit 1)
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/share/redditbox"
	@cp "$(RBX_RELEASE_METADATA)" "$(THEOS_STAGING_DIR)/usr/share/redditbox/release.json"
	@test -n "$(RBX_FIREWALL_APP)" || (echo "RBX_FIREWALL_APP is required; use scripts/build-mac.sh" && exit 1)
	@test -d "$(RBX_FIREWALL_APP)" || (echo "Firewall app not found: $(RBX_FIREWALL_APP)" && exit 1)
	@mkdir -p "$(THEOS_STAGING_DIR)/Applications"
	@cp -R "$(RBX_FIREWALL_APP)" "$(THEOS_STAGING_DIR)/Applications/RedditBoxFirewall.app"
