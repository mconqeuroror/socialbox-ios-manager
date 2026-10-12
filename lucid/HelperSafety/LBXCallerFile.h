#import <Foundation/Foundation.h>

// Read-only on-disk check, not a code-signing or in-memory attestation. The
// caller must independently bind this path to a kernel-authenticated process.
FOUNDATION_EXPORT BOOL LBXVerifyCallerFile(NSString *path, off_t expectedSize,
                                          NSString *expectedSHA256);
