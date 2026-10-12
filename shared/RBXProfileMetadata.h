#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Organizational metadata only. Never use these values in identity or traffic policy.
static inline NSArray<NSString *> *RBXProfileRoles(void) {
    return @[@"signup", @"warmup", @"spam", @"default"];
}
static inline NSString *RBXProfileRole(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [RBXProfileRoles() containsObject:value] ? value : @"default";
}
static inline BOOL RBXProfileNotesValid(id _Nullable value) {
    // Count Unicode scalar values, matching cloud Array.from(), not UTF-16 units.
    if (![value isKindOfClass:NSString.class]) return NO;
    NSData *scalars = [value dataUsingEncoding:NSUTF32LittleEndianStringEncoding allowLossyConversion:NO];
    return scalars && scalars.length / 4 <= 200;
}
static inline BOOL RBXProfileNicknameValid(id _Nullable value) {
    if (![value isKindOfClass:NSString.class] || ![value length] ||
        ![value isEqual:[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]] ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    NSData *scalars = [value dataUsingEncoding:NSUTF32LittleEndianStringEncoding allowLossyConversion:NO];
    return scalars && scalars.length / 4 <= 120;
}
// The optional profile label is organizational metadata. The central-store
// name remains the legacy fallback and installation name; a rename never
// rewrites bundle IDs, signed app files, identity, storage paths or credentials.
static inline NSString *RBXProfileDisplayName(NSDictionary *profile, id _Nullable legacyName, NSString *identifier) {
    if (RBXProfileNicknameValid(profile[@"nickname"])) return profile[@"nickname"];
    return [legacyName isKindOfClass:NSString.class] && [legacyName length] ? legacyName : identifier;
}
static inline NSDictionary *RBXProfileMetadata(NSDictionary *profile) {
    id revision = profile[@"metadataRevision"];
    NSMutableDictionary *metadata = [@{@"role": RBXProfileRole(profile[@"role"]),
        @"notes": RBXProfileNotesValid(profile[@"notes"]) ? profile[@"notes"] : @"",
        @"metadataRevision": [revision isKindOfClass:NSNumber.class] && [revision longLongValue] >= 0 ? revision : @0} mutableCopy];
    if (RBXProfileNicknameValid(profile[@"nickname"])) metadata[@"nickname"] = profile[@"nickname"];
    return metadata;
}
// An accepted POST may echo an old installation name outside the new rename
// limit. Keep that name in its legacy store, not in the new optional label.
// Strip only the exact value we sent; retain every other raw field so the
// registry still rejects malformed roles, notes, revisions or a changed label.
static inline NSDictionary *RBXMetadataReplyWithLegacyName(NSDictionary *reply, NSString *sentName) {
    id name = reply[@"nickname"];
    if ([name isKindOfClass:NSString.class] && [name isEqual:sentName] && !RBXProfileNicknameValid(name)) {
        NSMutableDictionary *compatible = [reply mutableCopy];
        [compatible removeObjectForKey:@"nickname"];
        return compatible;
    }
    return reply;
}
static inline BOOL RBXMetadataAcknowledgesLocalEdit(NSDictionary *local, NSDictionary *remote) {
    NSDictionary *left = RBXProfileMetadata(local), *right = RBXProfileMetadata(remote);
    return [local[@"metadataDirty"] isEqual:@YES] &&
        [right[@"metadataRevision"] longLongValue] > [left[@"metadataRevision"] longLongValue] &&
        [left[@"role"] isEqual:right[@"role"]] && [left[@"notes"] isEqual:right[@"notes"]] &&
        (!left[@"nickname"] || [left[@"nickname"] isEqual:right[@"nickname"]]);
}
NS_ASSUME_NONNULL_END
