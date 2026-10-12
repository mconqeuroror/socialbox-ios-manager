#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

// Read-only projection of the already app-scoped daemon publication. Never a
// launch authorization: freshness, license and daemon gates remain authoritative.
static inline NSString *RBXWorkspaceText(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static inline double RBXWorkspaceTimestamp(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? [value doubleValue] : 0;
}
static inline NSString *RBXWorkspaceDeviceText(NSDictionary *row) {
    NSDictionary *identity = [row[@"identityEditor"] isKindOfClass:NSDictionary.class] ? row[@"identityEditor"] : @{};
    NSString *model = RBXWorkspaceText(identity[@"marketingName"]);
    if (!model.length) model = RBXWorkspaceText(row[@"identity"]);
    NSString *version = RBXWorkspaceText(identity[@"iosVersion"]);
    if (!model.length) return @"Identity not available";
    return version.length ? [NSString stringWithFormat:@"%@ · iOS %@",model,version] : model;
}
static inline NSArray<NSDictionary *> *RBXWorkspaceRows(id input, NSString *query, NSInteger sort) {
    NSArray *rows = [input isKindOfClass:NSArray.class] ? input : @[];
    NSString *needle = [RBXWorkspaceText(query) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *result = [NSMutableArray array];
    for (id value in rows) {
        if (![value isKindOfClass:NSDictionary.class] || !RBXWorkspaceText(value[@"id"]).length) continue;
        NSDictionary *row = value;
        NSString *search = [@[RBXWorkspaceText(row[@"name"]),RBXWorkspaceText(row[@"id"]),RBXWorkspaceDeviceText(row),RBXWorkspaceText(row[@"country"])] componentsJoinedByString:@" "];
        NSDictionary *sentinel = [row[@"isolationSentinel"] isKindOfClass:NSDictionary.class] ? row[@"isolationSentinel"] : @{};
        NSDictionary *replacement = [row[@"replacementState"] isKindOfClass:NSDictionary.class] ? row[@"replacementState"] : @{};
        BOOL recovery = row[@"deletionState"] || row[@"profileError"] || [sentinel[@"alert"] isEqual:@YES] || replacement.count;
        if (!needle.length || recovery || [search rangeOfString:needle options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound) [result addObject:row];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = NSOrderedSame;
        if (sort == 0) {
            double x = RBXWorkspaceTimestamp(a[@"lastActiveAt"]), y = RBXWorkspaceTimestamp(b[@"lastActiveAt"]);
            order = x == y ? NSOrderedSame : (x > y ? NSOrderedAscending : NSOrderedDescending);
        } else {
            NSString *x = sort == 2 ? RBXWorkspaceDeviceText(a) : RBXWorkspaceText(a[@"name"]);
            NSString *y = sort == 2 ? RBXWorkspaceDeviceText(b) : RBXWorkspaceText(b[@"name"]);
            order = [x localizedStandardCompare:y];
        }
        return order == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
    }];
    return result;
}
static inline NSDictionary *RBXWorkspaceSelectedRow(id rows, NSString *identifier) {
    NSArray *valid = RBXWorkspaceRows(rows,@"",0);
    for (NSDictionary *row in valid) if ([row[@"id"] isEqual:identifier]) return row;
    for (NSDictionary *row in valid) if ([row[@"isActive"] boolValue]) return row;
    return valid.firstObject;
}
