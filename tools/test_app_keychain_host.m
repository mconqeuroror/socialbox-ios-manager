#import <Foundation/Foundation.h>
#import "../lucid/Inject/LBXInjectCommon.h"
static int Failures;
static void Check(BOOL ok, const char *label) {
    if (ok) return;
    Failures++;
    fprintf(stderr, "FAIL %s\n", label);
}
int main(void) {
    @autoreleasepool {
        Check(LBXInjectIsSupportedBundleID(@"com.burbn.instagram"), "ig");
        Check(LBXInjectIsSupportedBundleID(@"com.facebook.Facebook"), "fb");
        Check(!LBXInjectIsSupportedBundleID(@"com.twitter.twitter"), "no twitter");
        Check(!LBXInjectIsSupportedBundleID(@"com.facebook.Messenger"), "no messenger");
        Check([LBXInjectHostBundleID(@"com.burbn.instagram.notificationextension")
                  isEqual:@"com.burbn.instagram"],
              "ig extension host");
        Check([LBXInjectHostBundleID(@"com.facebook.Facebook.ShareExtension")
                  isEqual:@"com.facebook.Facebook"],
              "fb extension host");
        Check(LBXInjectHostBundleID(@"com.facebook.Messenger") == nil, "messenger not hosted");
        Check(LBXInjectHostBundleID(@"com.atebits.Tweetie2") == nil, "twitter not hosted");
        if (Failures) return 1;
        puts("PASS: app-keychain host mapping");
        return 0;
    }
}
