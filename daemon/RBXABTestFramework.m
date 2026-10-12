#import "RBXABTestFramework.h"
#import "RBXCentralStore.h"

// A/B framework. Group assignment is persisted in the central store
// (containers.<id>.attest.group) so the tweak's effective-mode resolution and
// the dashboard report read the same source of truth.

@implementation RBXABTestFramework

+ (void)assignGroupForContainer:(NSString *)containerId {
    if (!containerId.length) return;

    // 50/50 via arc4random_uniform(2)
    NSString *group = (arc4random_uniform(2) == 0) ? @"A" : @"B";

    RBXCentralStore *store = [RBXCentralStore sharedStore];
    [store update:^(NSMutableDictionary *doc) {
        if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) {
            doc[@"containers"] = [NSMutableDictionary dictionary];
        }
        NSMutableDictionary *conts = doc[@"containers"];
        NSMutableDictionary *cont = [conts[containerId] isKindOfClass:[NSMutableDictionary class]] ?
            [conts[containerId] mutableCopy] : [NSMutableDictionary dictionary];

        NSMutableDictionary *attest = [cont[@"attest"] isKindOfClass:[NSDictionary class]] ?
            [cont[@"attest"] mutableCopy] : [NSMutableDictionary dictionary];
        attest[@"group"] = group;
        attest[@"mode"] = @"auto";   // group default drives it until overridden
        cont[@"attest"] = attest;

        if (![cont[@"createdAt"] isKindOfClass:[NSNumber class]]) {
            cont[@"createdAt"] = @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]);
        }

        conts[containerId] = cont;
    }];
}

+ (void)markMissionCompleted:(NSString *)containerId {
    if (!containerId.length) return;
    RBXCentralStore *store = [RBXCentralStore sharedStore];
    [store update:^(NSMutableDictionary *doc) {
        if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) return;
        NSMutableDictionary *conts = doc[@"containers"];
        NSMutableDictionary *cont = [conts[containerId] isKindOfClass:[NSMutableDictionary class]] ?
            [conts[containerId] mutableCopy] : nil;
        if (!cont) return;
        cont[@"missionCompleted"] = @YES;
        conts[containerId] = cont;
    }];
}

+ (NSString *)groupForContainer:(NSString *)containerId {
    NSDictionary *doc = [RBXCentralStore sharedStore].dictionary;
    NSString *group = doc[@"containers"][containerId][@"attest"][@"group"];
    return [group isKindOfClass:[NSString class]] ? group : nil;
}

@end
