#pragma once
#import "RBXAppScope.h"
#import "RBXProfileMetadata.h"

// Defaults fill a new form only. An existing draft, including an explicitly
// empty country (Auto), wins. Submission still uses the operator's form values
// and the daemon independently validates country and proxy consistency.
static inline NSDictionary *RBXCreationDefaults(NSUserDefaults *defaults,
    NSDictionary *descriptor, NSDictionary *draft) {
    if (!RBXAppDescriptorIsRegistered(descriptor)) return @{@"country":@"", @"role":@"default"};
    id country = draft[@"country"] ?: [defaults objectForKey:RBXAppScopedPreferenceKey(@"RBXDefaultCountry", descriptor)];
    id role = draft[@"role"] ?: [defaults objectForKey:RBXAppScopedPreferenceKey(@"RBXDefaultRole", descriptor)];
    return @{
        @"country": [country isKindOfClass:NSString.class] ?
            [[country stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString] : @"",
        @"role": RBXProfileRole(role),
    };
}
