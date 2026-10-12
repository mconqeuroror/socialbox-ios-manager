#import <Foundation/Foundation.h>
#import "../shared/RBXAppRegistry.h"

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) { @autoreleasepool {
    NSDictionary *reddit = RBXRedditAppDescriptor(), *facebook = RBXAppDescriptorForType(@"facebook");
    Check(reddit && facebook && RBXRegisteredAppDescriptors().count == 2, @"two registered apps");
    Check(RBXAppDescriptorForType(nil) == reddit && RBXAppDescriptorForProfile(@{}) == reddit, @"legacy defaults to Reddit");
    for (id invalid in @[@"", @"instagram", @"REDDIT", @42, NSNull.null, @[]]) {
        Check(!RBXAppDescriptorForType(invalid), @"unknown or malformed type fails closed");
        Check(!RBXAppDescriptorForProfile(@{@"appType":invalid}), @"invalid profile app type fails closed");
    }
    Check(!RBXAppDescriptorForProfile(nil), @"malformed profile does not default");
    NSDictionary *goldens = @{@"":@"14650fb0739d0383", @"a":@"44bd8ad473cd9906", @"test":@"975819681a395537",
        @"ui-check-20260911":@"ad16b04fa61f1978", @"hello-world":@"4d5116f596b217c0", @"žluťoučký":@"617535364d9270a7"};
    // Fixed vectors recorded from the pre-refactor algorithm. Expected values
    // are not calculated through the implementation under test.
    for (NSString *container in goldens) {
        NSString *bundle = [@"com.redditbox.profile.p" stringByAppendingString:goldens[container]];
        Check([RBXAppBundleIdentifier(reddit, container) isEqual:bundle], @"byte-identical legacy Reddit bundle ID");
        Check([RBXAppKeychainGroup(reddit, bundle) isEqual:[@"RBXCLONE00." stringByAppendingString:bundle]], @"byte-identical legacy keychain group");
        Check(RBXAppOwnsCloneBundleIdentifier(reddit, bundle) && !RBXAppOwnsCloneBundleIdentifier(facebook, bundle), @"Reddit family is exclusive");
        NSString *fb = RBXAppBundleIdentifier(facebook, container);
        Check([fb isEqual:[@"socialbox.profile.fb.p" stringByAppendingString:goldens[container]]], @"Facebook family reserved independently");
        Check(RBXAppOwnsCloneBundleIdentifier(facebook, fb) && !RBXAppOwnsCloneBundleIdentifier(reddit, fb), @"Facebook family is exclusive");
    }
    Check([RBXAppBundleIdentifier(reddit, nil) isEqual:@"com.redditbox.profile.p14650fb0739d0383"], @"legacy nil hash retained");
    Check([RBXAppKeychainGroup(reddit, nil) isEqual:@"RBXCLONE00.invalid"], @"legacy nil keychain fallback retained");
    for (NSString *bundle in @[@"com.redditbox", @"com.redditbox.daemon", @"com.redditbox.firewall", @"com.reddit.Reddit",
        @"com.redditbox.profile.p0123456789abcdef.extra", @"com.redditbox.profile.p0123456789abcde", @"com.redditbox.profile.p0123456789abcdeg",
        @"com.redditbox.profile.p0123456789abcdeF", @"prefix.com.redditbox.profile.p0123456789abcdef"])
        Check(!RBXAppOwnsCloneBundleIdentifier(reddit, bundle), @"only exact registered clone family qualifies");
    Check([reddit[@"sourceBundleIdentifier"] isEqual:@"com.reddit.Reddit"] && [reddit[@"sourceCachePath"] isEqual:@"/var/mobile/Library/RedditBox/Source/Reddit.app"] &&
        [reddit[@"sourceInboxPath"] isEqual:@"/var/mobile/Library/RedditBox/SourceInbox"] && [reddit[@"cloneExportPath"] isEqual:@"/var/mobile/Library/Preferences/com.redditbox.clone-export.ipa"] &&
        [reddit[@"cloneMarkerName"] isEqual:@".redditbox-clone.plist"] && [reddit[@"configNamespace"] isEqual:@"com.redditbox"] &&
        [reddit[@"teamIdentifier"] isEqual:@"RBXCLONE00"], @"legacy Reddit source, export, marker, namespace and team exact");
    Check(RBXAppDescriptorForBundleIdentifier(@"com.reddit.Reddit") == reddit &&
        RBXAppDescriptorForBundleIdentifier(@"com.facebook.Facebook") == facebook &&
        RBXAppDescriptorForBundleIdentifier(RBXAppBundleIdentifier(facebook, @"test")) == facebook &&
        !RBXAppDescriptorForBundleIdentifier(@"com.redditbox.daemon"), @"source and exact clone lookup are app scoped");
    Check([reddit[@"sourceImportRequestKey"] isEqual:@"RBXSourceImportRequestId"] &&
        [reddit[@"mdmExportDirectory"] isEqual:@"RedditBox-MDM"] &&
        [reddit[@"mdmProfileFilename"] isEqual:@"redditbox-per-app-vpn.mobileconfig"] &&
        [reddit[@"mdmMappingFilename"] isEqual:@"redditbox-mdm-app-mapping.json"] &&
        [reddit[@"originalDenyProfileId"] isEqual:@"__original_reddit_deny_only__"], @"legacy import and MDM names exact");
    Check([reddit[@"runnable"] boolValue] && ![facebook[@"runnable"] boolValue], @"Facebook remains inactive pending binary audit");
    NSMutableDictionary *forged = [reddit mutableCopy]; forged[@"cloneBundlePrefix"] = @"com.apple.";
    Check(!RBXAppBundleIdentifier(forged, @"test") && !RBXAppOwnsCloneBundleIdentifier(forged, @"com.apple.0123456789abcdef"), @"unregistered descriptor cannot broaden ownership");
    puts("App registry native regression tests: PASS");
} return 0; }
