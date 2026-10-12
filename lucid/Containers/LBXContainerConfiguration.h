#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Pure input validation. nil manual identifiers means generate later; nil proxy
// means none. This does not generate, reserve, persist or admit an identity.
FOUNDATION_EXPORT BOOL LBXContainerConfigurationValidateChoices(id _Nullable name,
    id _Nullable applications, id _Nullable manualIdentifiers, id _Nullable proxyReference);
// First invalid field key in fixed form order, or nil for valid choices. Uses
// the same validators; never returns private input or generates/persists data.
FOUNDATION_EXPORT NSString * _Nullable LBXContainerConfigurationInvalidChoiceField(id _Nullable name,
    id _Nullable applications, id _Nullable manualIdentifiers, id _Nullable proxyReference);

// Private source-owned configuration, not an installed owner container. The
// application list records a requested selection, never accepted runtime support.
// Identifiers are a supported syntactic subset, not an entire coherent hardware
// profile or evidence that a platform sees a new device. No backend is invoked.
// Random values are generated once at creation and then survive edits/reloads.
// Source-container IDs and nonempty proxy references are canonical lowercase
// UUIDs, preventing case aliases and accidental credential/URL proxy values.
// Manual identity UUIDs retain their accepted caller-supplied letter case.
@interface LBXContainerConfiguration : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly) uint64_t revision;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSArray<NSString *> *applications;
@property(nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *identifiers;
@property(nonatomic, readonly, copy) NSString *identifierMode;
@property(nonatomic, readonly, copy) NSString *proxyReference;

// Strict formatVersion=1 document. Every listed field is required. All returned
// dictionaries and strings are immutable snapshots, including nested values.
+ (nullable instancetype)fromDictionary:(id)dictionary error:(NSError **)error;
+ (nullable instancetype)createWithName:(NSString *)name
                          applications:(NSArray<NSString *> *)applications
                     manualIdentifiers:(nullable NSDictionary<NSString *, NSString *> *)manualIdentifiers
                        proxyReference:(nullable NSString *)proxyReference
                                 error:(NSError **)error;

// nil retains the current field; an empty proxy string clears its reference.
// A nonempty proxy reference is a UUID handle; resolver ownership is separate.
// A complete nonnil identifier dictionary selects manual mode. Every accepted
// edit increments revision once. A persistence owner must compare-and-swap the
// prior revision; this immutable value does not itself provide a storage CAS.
- (nullable LBXContainerConfiguration *)configurationByUpdatingName:(nullable NSString *)name
                                                     applications:(nullable NSArray<NSString *> *)applications
                                                manualIdentifiers:(nullable NSDictionary<NSString *, NSString *> *)manualIdentifiers
                                                   proxyReference:(nullable NSString *)proxyReference
                                                            error:(NSError **)error;
// Contains private name/identifier/proxy values; never put this in logs/receipts.
@property(nonatomic, readonly, copy) NSDictionary<NSString *, id> *privateDictionary;
// Only version/revision/count/mode/assignment flags. description uses this too.
@property(nonatomic, readonly, copy) NSDictionary<NSString *, id> *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
