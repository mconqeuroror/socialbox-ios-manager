#import <Foundation/Foundation.h>
#import "RBXIdentityFields.h"

@interface RBXProfileGenerator : NSObject

// Generates a synthetic catalog profile. This does not upgrade physical
// hardware or iOS. Draft generation does not save or change a used identity.

+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                          error:(NSError **)error;

// Optional explicit model/OS for the editor. Nil selects a catalog value;
// an unsupported explicit choice fails instead of silently choosing another.
+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                    productType:(NSString *)productType
                                     iosVersion:(NSString *)iosVersion
                                          error:(NSError **)error;

// Explicit app scope for unsaved drafts. Reddit retains the legacy document
// shape. Other registered apps carry appType; this does not enable execution.
+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                        appType:(NSString *)appType
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                          error:(NSError **)error;
+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                        appType:(NSString *)appType
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                    productType:(NSString *)productType
                                     iosVersion:(NSString *)iosVersion
                                          error:(NSError **)error;

// Auto-fix derived fields (timezone, locale, language, city) to match the
// proxy geo; returns fixed copy (§13.3).
+ (NSDictionary *)autofixProfile:(NSDictionary *)profile proxyCountry:(NSString *)country;

@end
