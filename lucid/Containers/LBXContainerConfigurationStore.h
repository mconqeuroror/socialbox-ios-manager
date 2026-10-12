#import <Foundation/Foundation.h>
@class LBXContainerConfiguration, LBXLicenseOwner;
NS_ASSUME_NONNULL_BEGIN

// Private creation/edit configuration storage for the authored runtime. These
// records are not recovered container metadata or an isolation/launch receipt.
// Production opens only root-owned storage. The owner is retained in-process;
// a mobile caller cannot supply a Boolean grant, path, or license receipt.
@interface LBXContainerConfigurationStore : NSObject
// Trusted root-local installer prerequisite. Creation refuses EVERY existing
// leaf and never repairs/adopts partial state. Production requires real/effective
// UID0. Failure can follow durable effects; preserve them for reviewed recovery.
// Absence alone is not first-install authority. No signed consumer API is relaxed.
+ (nullable instancetype)createPristineDirectory:(NSString *)directory
                                  licenseOwner:(LBXLicenseOwner *)owner error:(NSError **)error;
// PRIVATE immutable {directory,lock} facts, available before pairing. Neither
// fresh/empty/provenance nor admission is implied; never expose through IPC/logs.
// Refuses recursive observation in a held configuration proof/setup callback:
// compare that callback's passed namespace facts, rather than taking another lock.
- (nullable NSDictionary *)configurationNamespaceContextForTrustedInstaller:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// create:YES is explicit first-install setup. An existing store with a missing
// lock is rejected; create:NO never repairs or recreates lost storage.
+ (nullable instancetype)openDirectory:(NSString *)directory
                         licenseOwner:(LBXLicenseOwner *)owner
                               create:(BOOL)create error:(NSError **)error;
// In-process assembly check, not a transferable authorization result.
- (BOOL)usesLicenseOwner:(LBXLicenseOwner *)owner;
- (nullable NSArray<LBXContainerConfiguration *> *)configurations:(NSError **)error;
- (nullable LBXContainerConfiguration *)configurationWithIdentifier:(NSString *)identifier
                                                              error:(NSError **)error;
// nil + absent:YES + no error means the exact file is missing in a verified
// current store. Unsafe/unreadable/corrupt state always leaves absent:NO.
- (nullable LBXContainerConfiguration *)configurationWithIdentifier:(NSString *)identifier
                                                            absent:(BOOL *)absent error:(NSError **)error;
// An initial record has revision 1 and no expected record. Edits must replace
// the exact current immutable record and advance its revision by one. The
// deadline is absolute LBXLicenseIPCClock time, including queue/lock wait.
// A record durably reserved for closed allocation refuses EVERY edit with
// conflict, even a name-only change. The public configuration shape is intact.
// Legacy bare records are read/list only: their reservation state is UNKNOWN,
// so edits are blocked rather than implicitly migrating them to editable.
- (BOOL)commitConfiguration:(LBXContainerConfiguration *)configuration
                  replacing:(nullable LBXContainerConfiguration *)expected
             beforeDeadline:(double)deadline error:(NSError **)error;
// Trusted synchronous root consumer already inside THIS owner's exact active
// fence. These never start/nest a fence and reject outside/foreign contexts.
- (BOOL)commitConfiguration:(LBXContainerConfiguration *)configuration
                  replacing:(nullable LBXContainerConfiguration *)expected
 inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Trusted ordinary metadata consumer already inside THIS owner's exact active
// fence. Only a full-current strict unreserved record can be retired. The same
// UUID file permanently retains the full original document in a strict private
// tombstone; active reads/list hide it, but it is never confirmed absent or
// reusable. Exact retirement retry is read-only. No allocation/app-data purge,
// pending-slot discard, identity release, migration or reset is authorized.
// The caller must separately hold the appropriate pending policy/lock; this
// direct store API cannot prove pending emptiness and is not exposed over IPC.
// Every failure may follow publication: retain the full original UUID/document,
// freshly validate and reconcile; never recreate or silently regenerate it.
- (BOOL)retireConfiguration:(LBXContainerConfiguration *)configuration
 inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Read-only exact retirement reconciliation in the SAME owner fence/deadline.
// Missing/unsafe/nonretired/changed records never prove successful retirement.
- (BOOL)retirementCurrentForConfiguration:(LBXContainerConfiguration *)configuration
 inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Strict retired-record proof held through one synchronous trusted metadata
// callback. Only namespace observation is permitted in this scope; no active
// proof, retirement/write recursion, pending discard or runtime authority.
// Rechecks the full canonical tombstone, namespace and original live fence
// after the callback. A callback failure may follow pending publication.
- (BOOL)performWithExactRetirement:(LBXContainerConfiguration *)configuration
 inCurrentSourceOperationBeforeDeadline:(double)deadline
 operation:(BOOL (^)(NSDictionary *namespaceContext, NSError **error))operation error:(NSError **)error;
- (nullable LBXContainerConfiguration *)configurationWithIdentifier:(NSString *)identifier
                                                            absent:(BOOL *)absent
                       inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
- (nullable NSArray<LBXContainerConfiguration *> *)configurationsInCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
- (nullable NSDictionary *)configurationNamespaceContextInCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Read-only full-current edit eligibility: explicit envelope:false is required.
// Reserved or legacy UNKNOWN records conflict before any pending stage. During
// the exact proof callback below, only this SAME record may be queried and the
// already-held lock is reused; no mutable Boolean/result conveys authority.
- (BOOL)isConfigurationEditable:(LBXContainerConfiguration *)configuration
 inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Normal pending->configuration order: pins full exact current document under
// configuration.lock while a synchronous trusted callback publishes stage or
// proof-clear. ONLY namespace observation and same-record editable eligibility
// may reenter this store in that callback; no nested owner/fence/other API,
// established lock acquisition or asynchronous escape is allowed. Rechecks
// exact document, namespace, held lock and admission after possible effects.
- (BOOL)performWithExactConfiguration:(LBXContainerConfiguration *)configuration
 inCurrentSourceOperationBeforeDeadline:(double)deadline
              operation:(BOOL (^)(NSDictionary *namespaceContext,NSError **error))operation error:(NSError **)error;
// INITIAL SETUP ONLY: exact inventory must contain only configuration.lock.
// Holds that lock while operation receives immutable {directory,lock} facts.
// Callback must synchronously create ONLY fresh pending infrastructure, never
// acquire an established pending lock, recursively call this store/owner except
// verifyHeldEmptyNamespaceContext below, or
// escape asynchronously. This one pristine config->first-pending-publication
// exception does not change normal pending->config order. Rechecks namespace,
// emptiness and admission afterward; failure may follow publication, no repair.
- (BOOL)performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:(double)deadline
              operation:(BOOL (^)(NSDictionary *namespaceContext,NSError **error))operation error:(NSError **)error;
// Narrow trusted installation-proof consumption seam. Only the ORIGINAL
// borrowed immutable context object while THIS store's empty callback is active
// on its exact owner queue/deadline can match. Rechecks held descriptor/namespace
// and exact emptiness without acquiring another lock. Copied/escaped contexts
// cannot be replayed as authority, and the Boolean is not a transferable grant.
- (BOOL)verifyHeldEmptyNamespaceContext:(NSDictionary *)namespaceContext
 inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Trusted root-local allocation assembly only. Must run synchronously inside
// this store owner's EXISTING source-operation fence with its exact deadline;
// never starts a nested fence. Under configuration.lock, exact full current
// configuration CAS sets an irreversible reservation in that same UUID file.
// Exact retries are idempotent. Failures can follow durable reservation: retain
// the full candidate/UUID and reconcile; no ordinary thaw/release is provided.
- (BOOL)reserveConfigurationForClosedAllocation:(LBXContainerConfiguration *)configuration
                                 beforeDeadline:(double)deadline error:(NSError **)error;
// Read-only exact reservation assertion inside the same active owner fence.
// Requires a strict envelope with reserved:true. Legacy UNKNOWN or false is a
// conflict; this never converts, refreezes or adopts an old allocation journal.
- (BOOL)allocationReservationCurrentForConfiguration:(LBXContainerConfiguration *)configuration
                                        beforeDeadline:(double)deadline error:(NSError **)error;
@end
#if LBX_CONTAINER_STORE_TESTING
@interface LBXContainerConfigurationStore (PristineTesting)
+ (void)testPristineBoundaryHandler:(nullable void (^)(NSString *boundary))handler;
+ (void)testStopPristineAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
