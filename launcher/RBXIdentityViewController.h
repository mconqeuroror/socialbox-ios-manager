#import <UIKit/UIKit.h>

@interface RBXIdentityViewController : UIViewController
@property(nonatomic) BOOL focusRegionOnAppear;
// Present an unsaved daemon-owned creation draft through the same editor.
@property(nonatomic, copy) NSString *creationDraftToken;
@property(nonatomic, copy) NSNumber *creationDraftRevision;
- (instancetype)initWithContainerRow:(NSDictionary *)row;
- (instancetype)initWithContainerRow:(NSDictionary *)row simpleMode:(BOOL)simpleMode;
@end
