#import <Foundation/Foundation.h>
#import "RBXProfileMetadata.h"
int main(void) { @autoreleasepool {
    NSCAssert([RBXProfileRole(nil) isEqual:@"default"], @"legacy default");
    NSCAssert([RBXProfileRole(@42) isEqual:@"default"], @"invalid metadata cannot affect isolation");
    NSCAssert([RBXProfileMetadata(@{})[@"metadataRevision"] isEqual:@0], @"unsynced legacy revision");
    NSString *emoji = @"😀";
    NSString *twoHundred = [@"" stringByPaddingToLength:400 withString:emoji startingAtIndex:0];
    NSCAssert(RBXProfileNotesValid(twoHundred), @"200 Unicode scalars accepted");
    NSCAssert(!RBXProfileNotesValid([twoHundred stringByAppendingString:emoji]), @"201 scalars rejected");
    NSCAssert(!RBXProfileNotesValid(@42), @"non-string rejected");
    NSCAssert(!RBXProfileNotesValid(nil), @"nil rejected");
    NSDictionary *pending = @{@"role": @"warmup", @"notes": @"observed", @"metadataRevision": @2, @"metadataDirty": @YES};
    NSCAssert(RBXMetadataAcknowledgesLocalEdit(pending, @{@"role": @"warmup", @"notes": @"observed", @"metadataRevision": @3}), @"Lost successful response is recoverable");
    NSCAssert(!RBXMetadataAcknowledgesLocalEdit(pending, @{@"role": @"warmup", @"notes": @"other edit", @"metadataRevision": @3}), @"Divergent edits are not discarded");
    NSCAssert(!RBXMetadataAcknowledgesLocalEdit(pending, @{@"role": @"warmup", @"notes": @"observed", @"metadataRevision": @2}), @"Old snapshot cannot acknowledge a pending edit");
    NSMutableDictionary *renamed = [pending mutableCopy]; renamed[@"nickname"] = @"Local label";
    NSCAssert(!RBXMetadataAcknowledgesLocalEdit(renamed, @{@"role":@"warmup",@"notes":@"observed",@"metadataRevision":@3,@"nickname":@"Other label"}), @"A divergent cloud name cannot acknowledge a local rename");
    NSCAssert(RBXMetadataAcknowledgesLocalEdit(renamed, @{@"role":@"warmup",@"notes":@"observed",@"metadataRevision":@3,@"nickname":@"Local label"}), @"Lost rename response can be acknowledged by exact newer snapshot");
    NSCAssert(!RBXMetadataAcknowledgesLocalEdit(renamed, @{@"role":@"warmup",@"notes":@"observed",@"metadataRevision":@3}), @"Missing cloud label cannot discard rename");
    NSString *name120 = [@"" stringByPaddingToLength:240 withString:emoji startingAtIndex:0];
    NSCAssert(RBXProfileNicknameValid(name120), @"120 Unicode scalars accepted for name");
    NSCAssert(!RBXProfileNicknameValid([name120 stringByAppendingString:emoji]), @"121 name scalars rejected");
    for (id invalid in @[@"", @" ", @" leading", @"trailing ", @"line\nbreak", @"format\u200Bmark", @42, NSNull.null])
        NSCAssert(!RBXProfileNicknameValid(invalid), @"invalid labels rejected");
    NSCAssert([RBXProfileDisplayName(@{}, @"Old label", @"canonical-id") isEqual:@"Old label"], @"legacy presentation unchanged");
    NSCAssert([RBXProfileDisplayName(@{}, nil, @"canonical-id") isEqual:@"canonical-id"], @"missing legacy name uses existing ID");
    NSCAssert([RBXProfileDisplayName(@{@"nickname":@"Reviewed name"}, @"Old label", @"canonical-id") isEqual:@"Reviewed name"], @"reviewed label precedes fallback");
    NSCAssert(([RBXProfileMetadata(@{}) isEqual:@{@"role":@"default",@"notes":@"",@"metadataRevision":@0}]), @"legacy metadata shape unchanged");
    NSString *legacyLong = [@"L" stringByPaddingToLength:128 withString:@"L" startingAtIndex:0];
    NSDictionary *echo = @{@"nickname":legacyLong,@"role":@"default",@"notes":@"kept",@"metadataRevision":@5};
    NSDictionary *compatible = RBXMetadataReplyWithLegacyName(echo, legacyLong);
    NSCAssert(!compatible[@"nickname"] && [compatible[@"notes"] isEqual:@"kept"], @"Exact legacy echo keeps old display fallback while applying valid metadata");
    NSCAssert(RBXMetadataReplyWithLegacyName(echo, @"Different label") == echo, @"Changed invalid cloud label remains visible to strict validator");
    NSDictionary *malformedEcho = @{@"nickname":legacyLong,@"role":@42,@"notes":@42,@"metadataRevision":@-1};
    NSCAssert([RBXMetadataReplyWithLegacyName(malformedEcho, legacyLong)[@"role"] isEqual:@42], @"Compatibility never normalizes malformed unrelated fields");
    puts("profile metadata native tests passed");
} return 0; }
