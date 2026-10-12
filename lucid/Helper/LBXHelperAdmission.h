#pragma once
#import <Foundation/Foundation.h>
#import <bsm/audit.h>

NS_ASSUME_NONNULL_BEGIN
// Admits root (0) and mobile (501) peers whose audited executable path matches
// the SocialBox manager; root may also be this helper or SocialBoxCLI. When
// product digests are still zero, path + ownership checks apply without hash
// pinning. Helper self-admission never hash-pins (avoids digest fixed-point).
FOUNDATION_EXPORT BOOL LBXHelperAdmitAuditToken(audit_token_t token);
NS_ASSUME_NONNULL_END
