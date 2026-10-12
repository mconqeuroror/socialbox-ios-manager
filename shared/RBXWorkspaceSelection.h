#pragma once
#import "RBXAppRegistry.h"
#import "RBXProfileIdentifier.h"

// One global selection, independent of profile count. This is launch intent,
// never a network lease, capability grant, or substitute for profile admission.
static inline NSString *RBXWorkspaceSelectedID(id record, NSString *appType) {
    if (![record isKindOfClass:NSDictionary.class] ||
        ![record[@"formatVersion"] isEqual:@1] ||
        ![record[@"phase"] isEqual:@"selected"] ||
        ![record[@"appType"] isEqual:appType] || !RBXAppDescriptorForType(appType) ||
        ![record[@"requestId"] isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:record[@"requestId"]] ||
        !RBXCanonicalProfileIdentifier(record[@"containerId"])) return nil;
    return record[@"containerId"];
}

// The caller owns serialization and checked durable publication. A switching
// record deliberately has no previous target to fall back to after a crash.
static inline BOOL RBXSelectWorkspace(NSString *appType, NSString *container,
    NSString *requestID, BOOL (^persist)(NSDictionary *), BOOL (^closeStopDrain)(void),
    BOOL (^revalidate)(void)) {
    if (![appType isKindOfClass:NSString.class] || !RBXAppDescriptorForType(appType) ||
        !RBXCanonicalProfileIdentifier(container) || ![requestID isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:requestID]) return NO;
    NSMutableDictionary *record = [@{@"formatVersion":@1, @"appType":appType,
        @"containerId":container, @"requestId":requestID, @"phase":@"switching"} mutableCopy];
    if (!persist(record.copy) || !closeStopDrain() || !revalidate()) return NO;
    record[@"phase"] = @"selected";
    return persist(record.copy);
}
