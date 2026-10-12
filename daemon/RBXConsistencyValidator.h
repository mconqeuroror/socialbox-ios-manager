#import <Foundation/Foundation.h>

// §13 of PLAN.md — smart consistency validator.
// Hard errors block container launch; warnings surface in prefs UI.

@interface RBXConsistencyValidator : NSObject

+ (NSDictionary *)validatedProfile:(NSDictionary *)profile error:(NSError **)error;
+ (NSArray<NSString *> *)warningsForProfile:(NSDictionary *)profile;

@end
