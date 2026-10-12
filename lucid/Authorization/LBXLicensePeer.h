#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <sys/types.h>
// The audit token is read from this exact kernel message. A nil SHA is allowed
// only for a root service at the compiled privileged-service path; app/client
// callers must additionally match their compiled executable hash and size.
BOOL LBXLicenseAuthenticatePeer(xpc_object_t message, NSString *path, NSString *sha256, off_t size, uid_t uid);
// Manager-specific request policy: exact kernel message real UID501, effective
// UID0/501, and the same build-pinned root-owned executable/hash/size. Decoding
// uses Apple BSM routines; absent runtime symbols fail closed. No PID/env/request
// credential substitute, path provider, or change to the generic root policy.
BOOL LBXLicenseAuthenticateManagerPeer(xpc_object_t message, NSString *path, NSString *sha256, off_t size);
