#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Roles belong to our presentation layer. Only this adapter maps recovered
// class/getter/action names; a role is not backend admission or runtime evidence.
typedef NS_ENUM(NSInteger, SBScreen) {
    SBScreenUnknown = 0, SBScreenHome, SBScreenContainers, SBScreenLocation,
    SBScreenProxies, SBScreenSettings, SBScreenIdentity, SBScreenLicense,
    SBScreenStartup, SBScreenWelcome, SBScreenCountry, SBScreenCarrier,
    SBScreenModel, SBScreenVersion, SBScreenAllowedModels, SBScreenAppSelection,
    SBScreenBackups, SBScreenCloud, SBScreenCloudPush, SBScreenSessionDetails,
    SBScreenBulkProxyImport, SBScreenGuide, SBScreenMarket, SBScreenCheckout,
    SBScreenSessions, SBScreenSessionImport, SBScreenBulkCloudPush, SBScreenSessionExport, SBScreenSessionDestination
};

FOUNDATION_EXPORT SBScreen SBBackendScreen(id _Nullable controller);
FOUNDATION_EXPORT NSString *SBBackendScreenName(SBScreen screen);
FOUNDATION_EXPORT NSString * _Nullable SBBackendSupportedClassName(SBScreen screen);
FOUNDATION_EXPORT NSArray<NSString *> *SBBackendScreenClassNames(void);
// Entries: screen, className, core. The compatibility dictionary is solely an
// installer contract: className -> {mesh?, surface?, type?} uses reviewed ABI names.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *SBBackendScreenRegistry(void);
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary *> *SBBackendCompatibilityScreensDictionary(void);
// Each entry has className, selector, returnType, argumentType ("" or BOOL ABI).
// These callbacks only refresh presentation after the original implementation.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *SBBackendRefreshHooks(void);
// Reviewed error-only entrypoints. Their synchronous presentation context may
// use the diagnostic copy role; no title/text inference classifies an alert.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *SBBackendDiagnosticHooks(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SBBackendAppMetadata(void);
FOUNDATION_EXPORT BOOL SBBackendMetadataSupported(NSDictionary *metadata, NSString * _Nullable * _Nullable reason);

// Neutral keys are allowlisted per screen. Returned objects are existing UIKit
// views/layers only; this API never invokes a model factory, load or mutation.
FOUNDATION_EXPORT id _Nullable SBBackendReadObject(id owner, NSString *key,
                                                  NSString * _Nullable * _Nullable reason);
FOUNDATION_EXPORT BOOL SBBackendActionAvailable(id owner, NSString *action, id _Nullable nativeSender,
                                                NSString * _Nullable * _Nullable reason);
FOUNDATION_EXPORT BOOL SBBackendInvoke(id owner, NSString *action, id _Nullable nativeSender,
                                       NSString * _Nullable * _Nullable reason);
// Forward only the reviewed event on the existing getter-owned control. Its
// enabled state and original object identity remain authoritative. Moved controls
// remain valid; this API does not fabricate a replacement action sender.
FOUNDATION_EXPORT BOOL SBBackendSendControl(id owner, NSString *key, UIControlEvents event,
                                            NSString * _Nullable * _Nullable reason);

@interface SBContainerRecord : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSArray<NSString *> *appBundleIDs;
@property(nonatomic, readonly) BOOL appMembershipAvailable;
@property(nonatomic, readonly, copy, nullable) NSString *proxyTitle;
@property(nonatomic, readonly, copy, nullable) NSString *profileIdentifier;
@property(nonatomic, readonly, copy, nullable) NSString *folderName;
@end

@interface SBContainerSnapshot : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly, copy) NSString *reason;
@property(nonatomic, readonly, copy) NSArray<SBContainerRecord *> *containers;
@property(nonatomic, readonly, copy, nullable) NSString *activeIdentifier;
// Snapshot identity comes only from exact model containerID getters. Cached UI
// state is never a completed switch receipt, launch authority or isolation proof.
@end
FOUNDATION_EXPORT SBContainerSnapshot *SBBackendContainers(id owner);
// This is the original diffable-source lookup, never index -> inferred ID.
FOUNDATION_EXPORT SBContainerRecord * _Nullable SBBackendContainerAtIndexPath(id owner, NSIndexPath *indexPath);
FOUNDATION_EXPORT BOOL SBBackendContainerActionAvailable(id owner, NSString *action, NSString *identifier,
                                                         NSString * _Nullable * _Nullable reason);
// Resolve the current exact model by its ID for each dispatch. No captured model,
// displayed name, filtered row number, synthetic result or private writer is used.
FOUNDATION_EXPORT BOOL SBBackendInvokeContainerAction(id owner, NSString *action, NSString *identifier,
                                                      NSString * _Nullable * _Nullable reason);

#if SB_BACKEND_ADAPTER_TESTING || LBX_PRESENTATION_FIXTURE
// Synthetic host only. Production does not contain this override or accept a
// caller-supplied host path. The fixture still enforces class/IMP provenance/ABI.
FOUNDATION_EXPORT void SBBackendFixtureConfigure(NSDictionary * _Nullable metadata,
                                                 NSString * _Nullable executablePath);
#endif

NS_ASSUME_NONNULL_END
