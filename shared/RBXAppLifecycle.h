#pragma once
#import "RBXAppKeychainPolicy.h"
#import "RBXProfileIdentifier.h"

// FBLIFE-001. Legacy Reddit installation records keep their exact format-2
// identity fields. New app records carry an explicit immutable owner and the
// compiled complete group policy; caller-provided group lists are never authority.
static inline NSDictionary *RBXAppInstallationRecord(NSDictionary *descriptor, NSString *container) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || !RBXCanonicalProfileIdentifier(container)) return nil;
    NSString *bundle = RBXAppBundleIdentifier(descriptor, container);
    NSMutableDictionary *record = [@{@"formatVersion":@2, @"containerId":container, @"bundleIdentifier":bundle} mutableCopy];
    if (![descriptor[@"appType"] isEqual:@"reddit"]) {
        record[@"formatVersion"] = @3;
        record[@"appType"] = descriptor[@"appType"];
        record[@"sourceBundleIdentifier"] = descriptor[@"sourceBundleIdentifier"];
        record[@"keychainAccessGroup"] = RBXAppKeychainGroup(descriptor, bundle);
        [record addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor, bundle)];
    }
    return record.copy;
}

static inline NSDictionary *RBXAppInstallationRecordDescriptor(id record) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *descriptor = RBXAppDescriptorForType(record[@"appType"]);
    NSDictionary *expected = RBXAppInstallationRecord(descriptor, record[@"containerId"]);
    if (!expected) return nil;
    id version = record[@"formatVersion"];
    if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID()) return nil;
    for (NSString *key in expected) if (![expected[key] isEqual:record[key]]) return nil;
    if (![descriptor[@"appType"] isEqual:@"reddit"]) {
        id previous = record[@"hadPreviousInstall"], started = record[@"recoveryStarted"];
        BOOL boolean = [previous isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)previous) == CFBooleanGetTypeID();
        // Compatibility only for the shipped version-3 C-comparison producer:
        // integral 0/1, with every owner/group/phase field still validated.
        BOOL legacyInteger = [previous isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)previous) == CFNumberGetTypeID() &&
            !CFNumberIsFloatType((__bridge CFNumberRef)previous) &&
            ([previous isEqual:@0] || [previous isEqual:@1]);
        if ((!boolean && !legacyInteger) ||
            (started && (![started isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)started) != CFBooleanGetTypeID())) ||
            ![@[@"prepared", @"install-attempted", @"installed", @"committed"] containsObject:record[@"state"] ?: @""] ||
            (record[@"recoveryState"] && ![@"complete" isEqual:record[@"recoveryState"]])) return nil;
    }
    if ([descriptor[@"appType"] isEqual:@"reddit"] &&
        !RBXAppKeychainMetadataMatches(descriptor, record[@"bundleIdentifier"], record)) return nil;
    return descriptor;
}

static inline BOOL RBXAppInstallationRecordOwnedBy(id record, NSDictionary *descriptor) {
    return RBXAppDescriptorIsRegistered(descriptor) && [RBXAppInstallationRecordDescriptor(record) isEqual:descriptor];
}

// FBLIFE-002. Deletion authority survives retries in an app-bound target and
// journal. Legacy Reddit target/journal format 1 keeps its existing fields.
static inline NSDictionary *RBXAppDeletionTargetIdentity(NSDictionary *descriptor, NSString *container) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || !RBXCanonicalProfileIdentifier(container)) return nil;
    NSString *bundle = RBXAppBundleIdentifier(descriptor, container);
    NSMutableDictionary *target = [@{@"formatVersion":@1, @"containerId":container, @"bundleIdentifier":bundle,
        @"keychainAccessGroup":RBXAppKeychainGroup(descriptor, bundle)} mutableCopy];
    if (![descriptor[@"appType"] isEqual:@"reddit"]) {
        target[@"formatVersion"] = @2;
        target[@"appType"] = descriptor[@"appType"];
        target[@"sourceBundleIdentifier"] = descriptor[@"sourceBundleIdentifier"];
        [target addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor, bundle)];
    }
    return target.copy;
}

static inline NSDictionary *RBXAppDeletionTargetDescriptor(id target) {
    if (![target isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *descriptor = RBXAppDescriptorForType(target[@"appType"]);
    NSDictionary *expected = RBXAppDeletionTargetIdentity(descriptor, target[@"containerId"]);
    id version = target[@"formatVersion"];
    if (!expected || ![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID()) return nil;
    for (NSString *key in expected) if (![expected[key] isEqual:target[key]]) return nil;
    return RBXAppKeychainMetadataMatches(descriptor, target[@"bundleIdentifier"], target) ? descriptor : nil;
}

static inline NSDictionary *RBXAppDeletionJournalIdentity(NSDictionary *target) {
    NSDictionary *descriptor = RBXAppDeletionTargetDescriptor(target);
    if (!descriptor) return nil;
    NSMutableDictionary *record = [@{@"formatVersion":@1, @"containerId":target[@"containerId"], @"target":target} mutableCopy];
    if (![descriptor[@"appType"] isEqual:@"reddit"]) {
        record[@"formatVersion"] = @2; record[@"appType"] = descriptor[@"appType"];
    }
    return record.copy;
}

static inline NSDictionary *RBXAppDeletionJournalDescriptor(id record) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *descriptor = RBXAppDeletionTargetDescriptor(record[@"target"]);
    NSDictionary *expected = RBXAppDeletionJournalIdentity(record[@"target"]);
    id version = record[@"formatVersion"];
    if (!expected || ![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        ![RBXAppDescriptorForType(record[@"appType"]) isEqual:descriptor]) return nil;
    for (NSString *key in expected) if (![expected[key] isEqual:record[key]]) return nil;
    return descriptor;
}

// A retry must not consume a profile which reappeared under another app owner.
// Previously retained malformed bytes are recoverable; new unparseable bytes
// have no known owner and require inspection instead of destructive guessing.
static inline BOOL RBXAppDeletionEvidenceOwnerMatches(NSDictionary *journal, NSData *data) {
    NSDictionary *descriptor = RBXAppDeletionJournalDescriptor(journal);
    if (!descriptor) return NO;
    if (!data) return YES;
    if (![data isKindOfClass:NSData.class]) return NO;
    id profile = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([profile isKindOfClass:NSDictionary.class]) return [RBXAppDescriptorForProfile(profile) isEqual:descriptor];
    return [data isEqual:journal[@"profileEvidence"]] || [data isEqual:journal[@"finalProfileEvidence"]];
}

// FBLIFE-005. Replacement keeps two distinct immutable clone identities. The
// Reddit format-1 journal's identity fields remain byte-for-byte equivalent.
static inline NSDictionary *RBXAppReplacementJournalIdentity(NSDictionary *descriptor,
    NSString *oldID, NSString *newID) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || !RBXCanonicalProfileIdentifier(oldID) ||
        !RBXCanonicalProfileIdentifier(newID) || [oldID isEqual:newID] ||
        [RBXAppBundleIdentifier(descriptor, oldID) isEqual:RBXAppBundleIdentifier(descriptor, newID)]) return nil;
    NSMutableDictionary *identity = [@{@"formatVersion":@1, @"oldId":oldID, @"newId":newID} mutableCopy];
    if (![descriptor[@"appType"] isEqual:@"reddit"]) {
        identity[@"formatVersion"] = @2;
        identity[@"appType"] = descriptor[@"appType"];
        identity[@"sourceBundleIdentifier"] = descriptor[@"sourceBundleIdentifier"];
        identity[@"oldTarget"] = RBXAppDeletionTargetIdentity(descriptor, oldID);
        identity[@"newTarget"] = RBXAppDeletionTargetIdentity(descriptor, newID);
    }
    return identity.copy;
}

static inline NSDictionary *RBXAppReplacementJournalDescriptor(id record) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *descriptor = RBXAppDescriptorForType(record[@"appType"]);
    NSDictionary *expected = RBXAppReplacementJournalIdentity(descriptor, record[@"oldId"], record[@"newId"]);
    id version = record[@"formatVersion"];
    if (!expected || ![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID()) return nil;
    for (NSString *key in expected) if (![expected[key] isEqual:record[key]]) return nil;
    return descriptor;
}
