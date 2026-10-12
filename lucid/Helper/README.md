# SocialBoxHelper (source rebuild)

Theos rootless NSXPC helper. Identities come from `../Switching/LBXSocialBoxProduct.h`.

```
export THEOS=/Users/martin/Documents/Codex/2026-09-30/i/work/socialbox-import/work/theos
export LDID=/Users/martin/Documents/Codex/2026-09-30/i/work/socialbox-import/work/local-tools/bin/ldid
make -C lucid/Helper TARGET=iphone:clang:26.5:15.0 FINALPACKAGE=1 \
  TARGET_CODESIGN="$LDID" TARGET_CODESIGN_FLAGS=-S
bash tools/test_socialbox_helper_source.sh
```

`issueSandboxExtensionsForContainer:bundleID:reply:` is an honest 501 REFUSED stub.
