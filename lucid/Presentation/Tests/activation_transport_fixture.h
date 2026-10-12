#import <Foundation/Foundation.h>
NSUInteger SBTestLicenseRequestCount(void);
NSString *SBTestLicenseRequestedKey(void);
void SBTestLicenseComplete(NSString *result);
void SBTestLicenseCompleteFields(NSDictionary *overrides);
void SBTestLicenseReplay(void);
