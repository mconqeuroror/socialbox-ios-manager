#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Local catalog choices only. Selecting or cancelling never writes a profile;
// the caller still owns validation, pending-request and first-use locks.
@interface RBXCatalogPickerViewController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *options;
@property(nonatomic, copy, readonly, nullable) NSString *selectedValue;
@property(nonatomic, strong, readonly) UISearchController *search;
@property(nonatomic, copy) NSString *explanation;
- (instancetype)initWithTitle:(NSString *)title
                     options:(NSArray<NSDictionary *> *)options
               selectedValue:(nullable NSString *)selectedValue
                   selection:(void (^)(NSString *value))selection;
@end
NS_ASSUME_NONNULL_END
