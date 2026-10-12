#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// An owned modal configuration flow. Source UUID records never become legacy
// numeric container IDs or permission to launch, switch or erase app storage.
FOUNDATION_EXPORT NSString *SBSavedContainerSetupEntryTitle(void);
FOUNDATION_EXPORT void SBPresentSavedContainerSetups(UIViewController *presenter);
NS_ASSUME_NONNULL_END
