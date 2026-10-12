#import <Foundation/Foundation.h>

@interface RBXContainerRegistry : NSObject

// All containers on device (from profiles dir).
- (NSArray<NSString *> *)containerIds;
// Missing directory is an empty inventory; unreadable/unsafe directories fail.
- (nullable NSArray<NSString *> *)containerIdsWithError:(NSError **)error;

// Repairs derived identity fields in existing profiles at daemon startup.
- (void)migrateProfilesIfNeeded;
- (BOOL)migrateProfilesWithError:(NSError **)error;

// Provisions/repairs one OS-isolated app clone for every existing profile.
// A failed clone remains unusable and therefore cannot be launched.
- (void)migrateAppClonesIfNeeded;
- (BOOL)migrateAppClonesWithError:(NSError **)error;

// Load + validate a container profile. Returns nil and sets error if any hard
// consistency rule fails (§13.1 of PLAN.md); the daemon then refuses to launch.
- (NSDictionary *)validatedProfileForContainer:(NSString *)containerId error:(NSError **)error;

// Validate a restore candidate and local uniqueness before any profile publication.
- (NSDictionary *)validatedImportedProfile:(NSDictionary *)profile error:(NSError **)error;

// List validation failures/warnings for UI display.
- (NSArray<NSString *> *)warningsForContainer:(NSString *)containerId;

// Clone metadata and local-profile synchronization used by the switch path.
- (BOOL)ensureAppCloneForContainer:(NSString *)containerId error:(NSError **)error;
- (BOOL)syncProfileToCloneForContainer:(NSString *)containerId error:(NSError **)error;

// Per-container identity editor. The daemon derives coupled fields and rejects
// combinations that contradict the physical device or proxy country.
- (nullable NSDictionary *)identityEditorStateForContainer:(NSString *)containerId
                                                      error:(NSError **)error;
- (nullable NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)containerId randomize:(BOOL)randomize selection:(nullable NSDictionary *)selection error:(NSError **)error;
// Automatic region is an in-process daemon observation, never an IPC choice.
// This returns a private editable draft only; it never writes/reserves a profile.
- (nullable NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)containerId randomize:(BOOL)randomize selection:(nullable NSDictionary *)selection regionSuggestion:(nullable NSDictionary *)region error:(NSError **)error;
- (nullable NSDictionary *)previewIdentityChoices:(NSDictionary *)choices
                                      forContainer:(NSString *)containerId
                                              error:(NSError **)error;
- (BOOL)applyIdentityChoices:(NSDictionary *)choices
                toContainer:(NSString *)containerId
                      error:(NSError **)error;

// Create a new container (profile + store + optional proxy). Returns the id.
- (NSString *)createContainerWithId:(NSString *)containerId
                       proxyCountry:(NSString *)country
                           proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname
                              error:(NSError **)error;

// Create with a fresh daemon-derived region suggestion, before provisioning.
- (NSString *)createContainerWithId:(NSString *)containerId
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region
                              error:(NSError **)error;

// Read-only admission; Facebook source/runnable checks precede ID allocation,
// region lookup, identity reservation, profile/store writes and clone work.
- (BOOL)canCreateContainerForAppType:(NSString *)appType error:(NSError **)error;
- (NSString *)createContainerWithId:(NSString *)containerId appType:(NSString *)appType
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname error:(NSError **)error;
- (NSString *)createContainerWithId:(NSString *)containerId appType:(NSString *)appType
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region
                              error:(NSError **)error;

// Unsaved creation envelope: {formatVersion, preparedAt, profile, review}.
// Private profile bytes stay in the daemon. The sanitized review is safe to
// publish; editor details must use the private identity channel. No writes,
// reservations or clone work occur during preparation or editing.
- (nullable NSDictionary *)prepareCreationForContainer:(NSString *)containerId appType:(NSString *)appType
                                         proxyCountry:(NSString *)country regionSuggestion:(nullable NSDictionary *)region
                                                error:(NSError **)error;
- (nullable NSDictionary *)creationIdentityEditorDraftForProfile:(NSDictionary *)profile error:(NSError **)error;
- (nullable NSDictionary *)creationProfileByApplyingChoices:(NSDictionary *)choices
                                        toPreparedProfile:(NSDictionary *)prepared error:(NSError **)error;
// Caller supplies only its own retained envelope, never IPC profile bytes, and
// rechecks source/proxy/user bindings. Registry rechecks expiry, ID/app/country,
// reservations and live collisions. nil retains the legacy creation sequence.
- (nullable NSString *)createContainerWithId:(NSString *)containerId appType:(NSString *)appType
                              proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                                  nickname:(NSString *)nickname regionSuggestion:(nullable NSDictionary *)region
                           preparedProfile:(nullable NSDictionary *)prepared error:(NSError **)error;

// Delete profile, store entry, data dir, and pool slot. Refuses if active.
- (BOOL)deleteContainer:(NSString *)containerId error:(NSError **)error;
// Append-only hashed identifier history; deletion never releases reservations.
- (BOOL)reserveIdentityForProfile:(NSDictionary * _Nonnull)profile
                           error:(NSError * _Nullable * _Nullable)error;
// Metadata edits never change the clone identity, keychain or network lease.
- (BOOL)updateMetadata:(NSDictionary *)metadata forContainer:(NSString *)containerId
                 local:(BOOL)local error:(NSError **)error;
- (BOOL)discardMetadataChangesForContainer:(NSString *)containerId error:(NSError **)error;
// Sanitized durable deletion status. A record permanently reserves its ID.
- (nullable NSDictionary *)deletionStateForContainer:(NSString *)containerId;
// Internal read-only ownership proof from the validated durable deletion journal.
// Returns only the canonical app/group identity, never retained profile bytes.
- (nullable NSDictionary *)deletionIdentityForContainer:(NSString *)containerId error:(NSError **)error;
- (NSArray<NSDictionary *> *)pendingDeletionStates;
- (nullable NSArray<NSDictionary *> *)cloudDeletionRecordsWithError:(NSError **)error;
- (BOOL)recordRemoteRetirementForContainer:(NSString *)identifier binding:(NSDictionary *)binding error:(NSError **)error;

@end
