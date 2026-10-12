#import <UIKit/UIKit.h>
@interface RBXProxiesViewController : UITableViewController
// Selection was saved locally; this does not claim the network test passed.
@property(nonatomic, copy) void (^didSelectProxy)(void);
- (instancetype)initWithAppType:(NSString *)appType;
@end
