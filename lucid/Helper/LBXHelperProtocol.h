#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// NSXPC contract for SocialBoxHelper. Identities come from LBXSocialBoxProduct.h.
@protocol LBXHelperProtocol
- (void)pingWithReply:(void (^)(BOOL alive))reply;
- (void)killApp:(NSString *)bundleID reply:(void (^)(BOOL drained))reply;

- (void)atomicBatchSwap:(NSArray<NSDictionary *> *)operations
                  reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)atomicBatchSwapContents:(NSArray<NSDictionary *> *)operations
                          reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;

- (void)bootstrapContainerTreeForBundleID:(NSString *)bundleID
                              containerID:(long long)containerID
                                    reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)teardownContainerTreeForBundleID:(NSString *)bundleID
                             containerID:(long long)containerID
                                   reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;

- (void)dumpKeychainForBundleID:(NSString *)bundleID
                    containerID:(long long)containerID
                          reply:(void (^)(NSDictionary * _Nullable items, NSError * _Nullable error))reply;
- (void)restoreKeychainFromDictionary:(NSDictionary *)items
                          forBundleID:(NSString *)bundleID
                          containerID:(long long)containerID
                                reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)clearKeychainForBundleID:(NSString *)bundleID
                         nuclear:(BOOL)nuclear
                           reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;

- (void)switchContainerStorageForBundleID:(NSString *)bundleID
                            fromContainer:(long long)fromContainerID
                              toContainer:(long long)toContainerID
                                    reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)switchPhoneStorageFromContainer:(long long)fromContainerID
                            toContainer:(long long)toContainerID
                                  reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)deleteContainerStorage:(long long)containerID
                         reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)dataSeparationReportForContainer:(long long)containerID
                                   reply:(void (^)(NSDictionary *report))reply;
- (void)loadedContainerForBundleID:(NSString *)bundleID
                             reply:(void (^)(long long containerID))reply;

- (void)chownRecursiveToMobileAtPath:(NSString *)path
                               reply:(void (^)(BOOL ok, NSError * _Nullable error))reply;
- (void)startLocationSimulationAtLatitude:(double)latitude
                               longitude:(double)longitude
                                   reply:(void (^)(BOOL ok, NSString * _Nullable detail,
                                                   NSError * _Nullable error))reply;
- (void)stopLocationSimulationWithReply:(void (^)(BOOL ok, NSString * _Nullable detail,
                                                  NSError * _Nullable error))reply;

- (void)issueSandboxExtensionsForContainer:(long long)containerID
                                  bundleID:(NSString *)bundleID
                                     reply:(void (^)(NSArray<NSString *> * _Nullable tokens,
                                                     NSError * _Nullable error))reply;
@end

FOUNDATION_EXPORT NSErrorDomain const LBXHelperErrorDomain;
typedef NS_ENUM(NSInteger, LBXHelperErrorCode) {
    LBXHelperErrorInvalidArgument = 400,
    LBXHelperErrorUnauthorized = 403,
    LBXHelperErrorPathDenied = 404,
    LBXHelperErrorOperationFailed = 500,
    LBXHelperErrorRefused = 501,
};

NS_ASSUME_NONNULL_END
