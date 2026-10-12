#import <Foundation/Foundation.h>
#if !SB_UPDATE_FOUNDATION_ONLY
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const SBUpdateStateDidChangeNotification;
// Pure evaluation: no license, filesystem, preference or network access.
FOUNDATION_EXPORT NSDictionary *SBUpdateEvaluateManifest(id manifest, NSString *installedVersion, NSString *systemVersion);
FOUNDATION_EXPORT NSNumber * _Nullable SBUpdateSequence(NSString *version);
FOUNDATION_EXPORT NSURL *SBUpdatePageURL(void);
// Explicit user handoff only. URLs are fixed; a failed handler falls back to
// Zebra, then the owned instructions page. No install or container mutation.
typedef void (^SBUpdateURLOpener)(NSURL *url, void (^completion)(BOOL opened));
FOUNDATION_EXPORT void SBUpdateOpenRelease(NSDictionary *snapshot, SBUpdateURLOpener opener,
                                          void (^completion)(BOOL opened));

@interface SBUpdateService : NSObject
@property(nonatomic,readonly,copy) NSDictionary *snapshot;
+ (instancetype)sharedService;
// Main-thread actions. Construction/observation never makes a request.
- (void)checkForUpdates;
- (void)checkAutomaticallyIfDue;
@end

#if SB_UPDATE_TESTING
@interface SBUpdateService (Testing)
- (instancetype)initWithInstalledVersion:(NSString *)version systemVersion:(NSString *)systemVersion
                           configuration:(NSURLSessionConfiguration *)configuration
                                defaults:(NSUserDefaults *)defaults;
@end
#endif

#if !SB_UPDATE_FOUNDATION_ONLY
@interface SBAppUpdatesViewController : UIViewController
@end
// Registers an application lifecycle observer only for an existing, admitted
// five-controller shell. This function does not request or present anything.
FOUNDATION_EXPORT void SBUpdateObserveAdmittedWorkspace(UIViewController *owner);
#endif
NS_ASSUME_NONNULL_END
