#pragma once
#import <Foundation/Foundation.h>

// Wire/file contract shared by creation and cloud inventory. Never rewrite IDs.
static inline BOOL RBXCanonicalProfileIdentifier(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 128) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}
