# SocialBox.app (manager, source rebuild)

Theos rootless `APPLICATION` — bundle `com.socialbox.app`.

IG+FB containers UI over NSXPC `com.socialbox.helper.xpc`.

```
export THEOS=… LDID=…
make -C lucid/Manager TARGET=iphone:clang:26.5:15.0 FINALPACKAGE=1 \
  TARGET_CODESIGN="$LDID" TARGET_CODESIGN_FLAGS=-S
```

Install path: `/var/jb/Applications/SocialBox.app/SocialBox`.
