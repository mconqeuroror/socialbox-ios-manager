#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <SpringBoard/SBIcon.h>
#import <SpringBoard/SBIconView.h>

// Long-press the Reddit icon -> container picker (R1).
// Selecting a container writes the pending-launch record and rings the daemon's
// doorbell (darwin notification); the daemon owns kill+bind+relaunch.

static NSString *const kRedditBundleID = @"com.reddit.Reddit";

static NSArray<NSString *> *RBXContainerList(void) {
    // Container registry = profile files written by daemon / prefs UI.
    NSString *dir = @"/var/mobile/Library/Preferences/com.redditbox.profiles";
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f hasSuffix:@".json"]) {
            [ids addObject:[f stringByDeletingPathExtension]];
        }
    }
    if (ids.count == 0) return @[ @"default" ];
    return ids;
}

static void RBXRequestLaunchWithContainer(NSString *containerId) {
    // Darwin notifications carry no payload; the request goes via a plist the daemon
    // reads when the doorbell rings.
    NSDictionary *msg = @{@"action": @"launchContainer", @"container": containerId};
    [msg writeToFile:@"/var/mobile/Library/Preferences/com.redditbox.pending.plist" atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFSTR("com.redditbox.launchContainer"),
                                          NULL, NULL, TRUE);
}

// The icon's own context menu keeps working; we present our picker right after the
// long-press lands, before the system menu builds. Hooking the icon's touch-down
// handler this way is stable across iOS 15-17 SpringBoard builds.

%hook SBIconView

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
       willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
              completionHandler:(void (^)(UIContextMenuInteractionRendering))handler {
    %orig;

    SBIcon *icon = [self icon];
    if (!icon || ![icon.bundleIdentifier isEqualToString:kRedditBundleID]) return;

    // Present our container picker on top of the (still open) context menu flow.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RedditBox"
                                                                     message:@"Choose container"
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

        for (NSString *containerId in RBXContainerList()) {
            [alert addAction:[UIAlertAction actionWithTitle:containerId
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                RBXRequestLaunchWithContainer(containerId);
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"New container"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            NSDictionary *msg = @{@"action": @"createContainer", @"country": @"US"};
            [msg writeToFile:@"/var/mobile/Library/Preferences/com.redditbox.pending.plist" atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                  CFSTR("com.redditbox.containerAction"),
                                                  NULL, NULL, TRUE);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];

        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        [window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

%end
