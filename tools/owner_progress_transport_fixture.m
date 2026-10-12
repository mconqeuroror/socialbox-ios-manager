// Only linked by the explicit simulator fixture, never the owner profile.
#import <Foundation/Foundation.h>
static NSUInteger LicenseRequests, Validations;
void LBXSendLicenseRequest(NSString *operation, NSString *key, void (^completion)(NSDictionary *)) {
    (void)key;LicenseRequests++;if([operation isEqual:@"validate"])Validations++;
    if(completion)completion(@{@"result":@"unavailable"});
}
NSUInteger SBTestLicenseRequestCount(void) { return LicenseRequests; }
NSUInteger SBTestSavedSetupValidateCount(void) { return Validations; }
