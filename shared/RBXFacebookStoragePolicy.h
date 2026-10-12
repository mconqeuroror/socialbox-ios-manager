#pragma once
#import "RBXAppRegistry.h"

// FBSTORE-001. Exact App Group declarations in the hash-bound Facebook 578.1.0
// IPA; the family/Facebook defaults suites also have observed runtime callers.
// These are aliases to private clone storage, never granted shared entitlements.
static inline NSArray<NSString *> *RBXFacebookSharedStorageDomains(void) {
    return @[@"group.com.facebook.Facebook", @"group.com.facebook.family",
             @"group.com.metaplatforms.family", @"group.com.facebook.msysstorage"];
}
static inline NSString *RBXFacebookStorageRole(id domain) {
    if (![domain isKindOfClass:NSString.class]) return nil;
    NSUInteger i=[RBXFacebookSharedStorageDomains() indexOfObject:domain];
    return i==NSNotFound ? nil : @[@"app",@"family",@"meta-family",@"msys"][i];
}
static inline NSString *RBXFacebookPrivateStorageDomain(NSString *bundle, NSString *role) {
    return [bundle stringByAppendingFormat:@".sbx-storage.v1.%@",role];
}
static inline BOOL RBXFacebookOwnStorageBundle(NSString *bundle) {
    return RBXAppOwnsCloneBundleIdentifier(RBXAppDescriptorForType(@"facebook"),bundle);
}
// nil is the native standard-defaults initializer. Values/keys never change.
// Platform preference domains retain native OS authorization; that does not mean
// platform settings are private identities. Unknown app/group domains fail closed.
static inline BOOL RBXFacebookMapStorageDomain(NSString *bundle,id domain,NSString **output) {
    if(output)*output=nil;
    if(!RBXFacebookOwnStorageBundle(bundle))return NO;
    if(!domain)return YES;
    if(![domain isKindOfClass:NSString.class] || ![domain length])return NO;
    NSString *result=nil;
    if([domain isEqual:@"com.facebook.Facebook"] || [domain isEqual:bundle]) result=bundle;
    else {
        NSString *role=RBXFacebookStorageRole(domain);
        if(role) result=RBXFacebookPrivateStorageDomain(bundle,role);
        else for(NSString *source in RBXFacebookSharedStorageDomains()) {
            NSString *own=RBXFacebookPrivateStorageDomain(bundle,RBXFacebookStorageRole(source));
            if([domain isEqual:own]) {result=own;break;}
        }
    }
    if(!result && ([domain isEqual:NSGlobalDomain] || [domain isEqual:NSArgumentDomain] ||
        [domain isEqual:NSRegistrationDomain] || [domain hasPrefix:@"com.apple."])) result=domain;
    if(!result)return NO;
    if(output)*output=result;
    return YES;
}
