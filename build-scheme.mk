# One package variant per build; never infer it from the build host filesystem.
RBX_PACKAGE_SCHEME ?= rootless
export RBX_PACKAGE_SCHEME
ifeq ($(RBX_PACKAGE_SCHEME),rootless)
export THEOS_PACKAGE_SCHEME = rootless
ADDITIONAL_CFLAGS += -DRBX_PACKAGE_ROOTLESS=1
else ifeq ($(RBX_PACKAGE_SCHEME),rootful)
export THEOS_PACKAGE_SCHEME =
ADDITIONAL_CFLAGS += -DRBX_PACKAGE_ROOTLESS=0
else
$(error RBX_PACKAGE_SCHEME must be rootless or rootful)
endif
