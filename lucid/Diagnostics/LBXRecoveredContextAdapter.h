#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads only an already-existing SocialBox 3.1.0-1 containers controller, on the
/// main thread. Never constructs a controller/manager, refreshes metadata,
/// switches context, reads files, or reads identity/session/credential fields.
///
/// Result is an immutable JSON-compatible projection. `contexts` contains
/// {id, name, appBundleIDs, appMembershipStatus}; id is a canonical positive
/// decimal string. A stable positive selection
/// present in that list adds string `activeContainerID`, with activeSelectionStatus
/// OBSERVED_CACHED_UI. This is cached UI metadata, NOT runtime authority:
/// processBindingStatus is always UNBOUND, identityStatus UNKNOWN, and
/// isolationStatus/networkStatus NOT_RUN. Missing/unsupported/malformed inputs
/// return UNAVAILABLE with a controlled reason and no guessed selection.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LBXRecoveredContextSnapshot(
    id _Nullable existingContainersController);

#if defined(LBX_RECOVERED_CONTEXT_TESTING)
/// Native-fixture seam only; not compiled into the overlay. Runtime class,
/// image, selector/signature and main-thread checks remain active.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LBXRecoveredContextSnapshotForTesting(
    id _Nullable controller, id _Nullable bundleID, id _Nullable version,
    id _Nullable build, NSString *executablePath);
#endif

NS_ASSUME_NONNULL_END
