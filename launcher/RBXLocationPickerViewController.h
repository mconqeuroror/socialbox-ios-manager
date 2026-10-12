#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Map selection edits only the caller's unsaved draft. No CLLocationManager,
// geocoding, proxy request, gate change or profile write occurs here.
@interface RBXLocationPickerViewController : UIViewController
- (instancetype)initWithCatalog:(NSDictionary *)catalog country:(NSString *)country
                       latitude:(NSString *)latitude longitude:(NSString *)longitude
                   proxyCountry:(NSString *)proxyCountry observedCountry:(NSString *)observedCountry
                         locked:(BOOL)locked selection:(void (^)(NSDictionary *location))selection;
@end
NS_ASSUME_NONNULL_END
