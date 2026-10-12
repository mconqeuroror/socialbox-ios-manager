#import <Foundation/Foundation.h>

@interface RBXPasscodeStore : NSObject
+ (BOOL)hasPasscode;
+ (BOOL)verifyPasscode:(NSString *)passcode;
+ (BOOL)setPasscode:(NSString *)passcode error:(NSError **)error;
+ (BOOL)clearPasscode:(NSError **)error;
@end
