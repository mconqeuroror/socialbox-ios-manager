#pragma once
#import <Foundation/Foundation.h>

// The source-built application uses the existing SocialBox deployment and its
// pinned signer. No recovered program or external licensing service is needed.
static NSString *const RBXCloudProductionOrigin = @"https://redditspoof.vercel.app";

static inline NSString *RBXCloudConfiguredOrigin(id value) {
    if (value == nil) return RBXCloudProductionOrigin;
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : RBXCloudProductionOrigin;
}
