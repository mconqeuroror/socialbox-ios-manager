#import <Foundation/Foundation.h>
#import <math.h>

// Daemon-private, bounded, ephemeral authority for UI-003 creation previews.
// Callers serialize access on sSwitchQueue. Only opaque tokens and summaries
// cross IPC. Never accept an authoritative profile back from the launcher.
static inline NSError *RBXCreationDraftError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.creation-draft" code:409
        userInfo:@{NSLocalizedDescriptionKey:message}];
}
static inline NSDictionary *RBXCreationImmutableCopy(NSDictionary *value) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
        format:NULL error:nil] : nil;
}
static inline void RBXCreationPrune(NSMutableDictionary *store, NSTimeInterval now) {
    for (NSString *key in store.allKeys) {
        NSTimeInterval created = [store[key][@"envelope"][@"preparedAt"] doubleValue];
        if (!isfinite(now) || !isfinite(created) || created > now || now - created >= 300) [store removeObjectForKey:key];
    }
}
static inline NSDictionary *RBXCreationStoreDraft(NSMutableDictionary *store, NSDictionary *envelope,
    NSDictionary *metadata, NSDictionary *binding, NSTimeInterval now, NSError **error) {
    RBXCreationPrune(store, now);
    if (!isfinite(now) || !isfinite([envelope[@"preparedAt"] doubleValue]) || store.count >= 8 || ![envelope[@"profile"] isKindOfClass:NSDictionary.class] ||
        ![envelope[@"review"] isKindOfClass:NSDictionary.class] || !binding.count ||
        ![metadata[@"container"] length] || ![metadata[@"appType"] length] ||
        ![envelope[@"preparedAt"] isKindOfClass:NSNumber.class] ||
        [envelope[@"preparedAt"] doubleValue] > now || now - [envelope[@"preparedAt"] doubleValue] >= 300) {
        if (error) *error = RBXCreationDraftError(@"The preview is unavailable. Discard an older draft or prepare again.");
        return nil;
    }
    NSString *token = NSUUID.UUID.UUIDString;
    NSDictionary *record = RBXCreationImmutableCopy(@{@"token":token, @"revision":@1,
        @"envelope":envelope, @"metadata":metadata, @"binding":binding});
    if (!record) { if (error) *error = RBXCreationDraftError(@"The draft could not be retained."); return nil; }
    store[token] = record;
    return record;
}
static inline NSDictionary *RBXCreationGetDraft(NSMutableDictionary *store, NSString *token,
    NSString *container, NSString *appType, NSNumber *revision, NSDictionary *binding,
    NSTimeInterval now, NSError **error) {
    RBXCreationPrune(store, now);
    NSDictionary *record = [token isKindOfClass:NSString.class] ? store[token] : nil;
    if (!isfinite(now) || !record || ![record[@"metadata"][@"container"] isEqual:container] ||
        ![record[@"metadata"][@"appType"] isEqual:appType] ||
        (revision && ![record[@"revision"] isEqual:revision]) || !binding ||
        ![record[@"binding"] isEqual:binding]) {
        if (error) *error = RBXCreationDraftError(@"The preview expired or its source, proxy or review changed. Prepare and review again; no container was created.");
        return nil;
    }
    return record;
}
static inline NSDictionary *RBXCreationUpdateDraft(NSMutableDictionary *store, NSDictionary *record,
    NSDictionary *envelope, NSError **error) {
    if (!record || ![store[record[@"token"]] isEqual:record] ||
        ![record[@"envelope"][@"preparedAt"] isEqual:envelope[@"preparedAt"]]) {
        if (error) *error = RBXCreationDraftError(@"The draft changed. Reload before saving."); return nil;
    }
    NSMutableDictionary *updated = [record mutableCopy];
    updated[@"envelope"] = envelope;
    updated[@"revision"] = @([record[@"revision"] unsignedIntegerValue] + 1);
    NSDictionary *immutable = RBXCreationImmutableCopy(updated);
    if (!immutable) { if (error) *error = RBXCreationDraftError(@"The edited draft could not be retained."); return nil; }
    store[record[@"token"]] = immutable;
    return immutable;
}
static inline NSDictionary *RBXCreationPublicReview(NSDictionary *record) {
    return @{@"creationDraftToken":record[@"token"], @"creationDraftRevision":record[@"revision"],
        @"containerId":record[@"metadata"][@"container"], @"appType":record[@"metadata"][@"appType"],
        @"expiresAt":@([record[@"envelope"][@"preparedAt"] doubleValue] + 300),
        @"review":record[@"envelope"][@"review"]};
}
