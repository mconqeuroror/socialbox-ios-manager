#import "RBXRootListController.h"

@implementation RBXRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        PSSpecifier *notice = [PSSpecifier emptyGroupSpecifier];
        [notice setProperty:
            @"Open SocialBox for your license, containers, connection setup, cloud backups, and diagnostics."
            forKey:@"footerText"];
        _specifiers = [@[notice] mutableCopy];
    }
    return _specifiers;
}

@end
