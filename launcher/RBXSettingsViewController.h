#import <UIKit/UIKit.h>

@interface RBXSettingsViewController : UIViewController
- (instancetype)initWithWizardMode:(BOOL)wizardMode;
- (instancetype)initWithProxyMode:(BOOL)proxyMode;
- (instancetype)initWithAppType:(NSString *)appType wizardMode:(BOOL)wizardMode;
- (instancetype)initWithAppType:(NSString *)appType proxyMode:(BOOL)proxyMode;
// A settings workspace may import only its captured app type.
- (void)importSourceForAppType:(NSString *)appType;
@end
