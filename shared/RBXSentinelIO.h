#pragma once
#import "RBXCloneAcceptanceProbe.h"
#import "RBXIsolationSentinel.h"

static NSString *const RBXSentinelControlName = @"com.redditbox.sentinel-control.plist";
static NSString *const RBXSentinelReportName = @"com.redditbox.sentinel-report.plist";

// Descriptor-relative IO is for our own diagnostic control/receipt only. Probes
// never use these helpers; they go through the Foundation/Security callbacks.
static inline int RBXSentinelPrefs(NSString *home) {
    int root = open(home.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (root < 0) return -1;
    int dir = RBXAcceptanceDescend(root, @[@"Library", @"Preferences"]); close(root);
    if (dir >= 0 && !RBXAcceptanceDirectoryOwner(dir, 501, 0022)) { close(dir); return -1; }
    return dir;
}
static inline NSDictionary *RBXSentinelRead(int dir, NSString *name, uid_t owner) {
    NSData *data = RBXAcceptanceRead(dir, name, owner, 262144);
    id object = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}
static inline BOOL RBXSentinelWrite(int dir, NSString *name, NSDictionary *object, uid_t owner) {
    if (dir < 0 || ![@[RBXSentinelControlName, RBXSentinelReportName] containsObject:name]) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data.length || data.length > 262144) return NO;
    NSString *temp = [@".sentinel-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(dir, temp.UTF8String, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    BOOL ok = RBXAcceptanceWrite(fd,data) && (geteuid() != 0 || fchown(fd,owner,owner) == 0) &&
        fchmod(fd,owner == 0 ? 0444 : 0600) == 0;
    close(fd);
    if (ok) ok = renameat(dir,temp.UTF8String,dir,name.UTF8String) == 0;
    if (!ok) unlinkat(dir,temp.UTF8String,0);
    return ok;
}
static inline BOOL RBXSentinelControlValid(NSDictionary *control, NSString *bundle,
                                         NSString *ownUUID, NSTimeInterval now) {
    if (![control[@"schemaVersion"] isEqual:@1] || ![control[@"bundleIdentifier"] isEqual:bundle] ||
        ![control[@"dataUUID"] isEqual:ownUUID] || !RBXAcceptanceUUID(control[@"revision"]) ||
        ![control[@"settings"] isKindOfClass:NSDictionary.class] || !RBXSentinelSettings(control[@"settings"]) || !RBXSentinelFresh(control[@"issuedAt"],now,60) ||
        ![control[@"targets"] isKindOfClass:NSArray.class] || [control[@"targets"] count] > 64) return NO;
    NSMutableSet *seen = [NSMutableSet set];
    for (id target in control[@"targets"]) {
        if (![target isKindOfClass:NSDictionary.class] || !RBXAcceptanceBundle(target[@"bundleIdentifier"]) ||
            !RBXAcceptanceUUID(target[@"dataUUID"]) || [target[@"bundleIdentifier"] isEqual:bundle] ||
            [target[@"dataUUID"] isEqual:ownUUID] || [seen containsObject:target[@"bundleIdentifier"]] ||
            ![target[@"nonce"] isKindOfClass:NSString.class] ||
            ([target[@"nonce"] length] && !RBXAcceptanceUUID(target[@"nonce"])) ||
            !RBXSentinelFresh(target[@"witnessAt"],now,60) ||
            ![target[@"expiresAt"] isKindOfClass:NSNumber.class] ||
            !isfinite([target[@"expiresAt"] doubleValue])) return NO;
        for (NSString *key in @[@"keychainSeeded", @"defaultsSeeded"])
            if (!target[key] || CFGetTypeID((__bridge CFTypeRef)target[key]) != CFBooleanGetTypeID()) return NO;
        [seen addObject:target[@"bundleIdentifier"]];
    }
    return YES;
}

static inline BOOL RBXSentinelReady(NSDictionary *ready, NSString *bundle, pid_t pid) {
    if (![ready[@"allHooksInstalled"] isEqual:@YES] || ![ready[@"timestamp"] isKindOfClass:NSNumber.class] ||
        !isfinite([ready[@"timestamp"] doubleValue]) || ![ready[@"bundleIdentifier"] isEqual:bundle] ||
        ![ready[@"pid"] isEqual:@(pid)]) return NO;
    for (NSString *key in @[@"containerId", @"generation", @"bootEpoch"])
        if (![ready[key] isKindOfClass:NSString.class] || ![ready[key] length] || [ready[key] length] > 180) return NO;
    return YES;
}

static inline BOOL RBXSentinelReportValid(NSDictionary *report, NSDictionary *control,
                                        NSDictionary *ready, NSTimeInterval now) {
    if (![report[@"schemaVersion"] isEqual:@1] || ![report[@"revision"] isEqual:control[@"revision"]] ||
        !RBXSentinelFresh(report[@"timestamp"],now,[control[@"settings"][@"intervalMinutes"] doubleValue]*60+90) ||
        ![report[@"rows"] isKindOfClass:NSArray.class] || ![report[@"rows"] count] || [report[@"rows"] count] > 258 ||
        [report[@"timestamp"] doubleValue] < [ready[@"timestamp"] doubleValue]) return NO;
    for (NSString *key in @[@"containerId",@"bundleIdentifier",@"generation",@"bootEpoch",@"pid"])
        if (!ready[key] || ![report[key] isEqual:ready[key]]) return NO;
    NSMutableSet *unique = [NSMutableSet set];
    for (id row in report[@"rows"]) {
        if (![row isKindOfClass:NSDictionary.class] ||
            ![@[@"keychain-default",@"keychain-group",@"filesystem",@"defaults",@"pasteboard",@"pasteboard-challenge"] containsObject:row[@"probe"]] ||
            ![@[@"PASS",@"LEAK",@"NOT_RUN"] containsObject:row[@"status"]] ||
            ![row[@"target"] isKindOfClass:NSString.class] || [row[@"target"] length] > 20 ||
            ![row[@"detail"] isKindOfClass:NSString.class] || [row[@"detail"] length] > 240 ||
            ![row[@"code"] isKindOfClass:NSNumber.class]) return NO;
        NSString *key = [NSString stringWithFormat:@"%@/%@",row[@"probe"],row[@"target"]];
        if ([unique containsObject:key]) return NO;
        [unique addObject:key];
    }
    // Missing mandatory rows never imply success.
    NSMutableSet *expected = [NSMutableSet setWithObject:@"pasteboard/system"];
    NSUInteger count = [control[@"targets"] count];
    for (NSUInteger i = 0; i < MAX(count,1); i++) {
        NSString *target = count ? [NSString stringWithFormat:@"sibling-%lu",(unsigned long)i+1] : @"none";
        for (NSString *probe in @[@"keychain-default",@"keychain-group",@"filesystem",@"defaults"])
            [expected addObject:[NSString stringWithFormat:@"%@/%@",probe,target]];
    }
    if ([control[@"settings"][@"clipboardChallenge"] isEqual:@YES]) [expected addObject:@"pasteboard-challenge/system"];
    return [unique isEqual:expected];
}

// Call only after structural/process validation. Downgrade unsupported success
// claims without discarding a valid LEAK elsewhere in an older report. Neither
// this normalization nor a fresh NOT_RUN result clears the durable alert ledger.
static inline NSArray *RBXSentinelNormalizedRows(NSArray *rows) {
    NSMutableArray *normalized = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) {
        NSString *probe = row[@"probe"];
        BOOL weak = [row[@"status"] isEqual:@"PASS"] &&
            ([probe isEqual:@"pasteboard"] || [probe isEqual:@"pasteboard-challenge"] ||
             [probe isEqual:@"keychain-default"] || [row[@"target"] isEqual:@"none"] ||
             ([probe isEqual:@"keychain-group"] && ![row[@"code"] isEqual:@(errSecMissingEntitlement)]));
        if (weak) {
            NSMutableDictionary *copy = row.mutableCopy;
            copy[@"status"] = @"NOT_RUN";
            copy[@"detail"] = @"Reported success lacks the required independent witness or explicit access denial.";
            [normalized addObject:copy];
        } else [normalized addObject:row];
    }
    return normalized;
}
