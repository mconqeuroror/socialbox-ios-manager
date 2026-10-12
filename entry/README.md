# Retired helper application

This source records the separate `Facebook · SocialBox` shortcut shipped in local
0.1.26. Since 0.1.27 it is not part of `SUBPROJECTS`, version staging, or icon
registration. Upgrade unregisters only its exact bundle before dpkg removes the
obsolete package files. It is retained as historical evidence for UI-008.

The manager now displays **SocialBox**, keeping its existing bundle identity.
Ordinary App Store Facebook and Reddit icons still launch their original apps;
removing this shortcut does not implement selected-container routing for them.
