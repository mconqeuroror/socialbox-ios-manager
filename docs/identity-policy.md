# Synthetic identity policy

New profiles select a synthetic model and an OS/build/Darwin tuple from the catalog.
The physical phone is diagnostic context, not a profile validation constraint.
The device, MobileGestalt, sysctl/uname, display and GPU-name hooks consume the same
persisted tuple. Migration must not repin that tuple to the host OS. Manual edits
still need matching board/IMEI/model facts and cannot bypass identity freezing.

This is identity presentation, not hardware or OS emulation. An advertised newer
OS cannot supply absent framework methods, Metal capabilities, or a different TLS
implementation. Native compatibility must still be tested on the actual phone.
The catalog excludes iOS 16.7.10 from its iPhone 13/14 families; that release's
hardware set does not include those models.
