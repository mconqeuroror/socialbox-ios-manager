#pragma once
#import <Foundation/Foundation.h>
#import "../Helper/LBXHelperProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Synchronous NSXPC client for com.socialbox.helper.xpc. Intended for the
// SocialBox manager (mobile) and SocialBoxCLI (root).
@interface LBXHelperClient : NSObject
@property(nonatomic, readonly, getter=isConnected) BOOL connected;
- (BOOL)connect:(NSError *_Nullable *_Nullable)error;
- (void)invalidate;

- (BOOL)ping:(NSError *_Nullable *_Nullable)error;
- (BOOL)killApp:(NSString *)bundleID error:(NSError *_Nullable *_Nullable)error;
- (BOOL)bootstrapBundleID:(NSString *)bundleID
              containerID:(long long)containerID
                    error:(NSError *_Nullable *_Nullable)error;
- (BOOL)teardownBundleID:(NSString *)bundleID
             containerID:(long long)containerID
                   error:(NSError *_Nullable *_Nullable)error;
- (BOOL)atomicBatchSwap:(NSArray<NSDictionary *> *)operations
                  error:(NSError *_Nullable *_Nullable)error;
- (BOOL)atomicBatchSwapContents:(NSArray<NSDictionary *> *)operations
                          error:(NSError *_Nullable *_Nullable)error;
// Drains the app, saves the live data container payload into the slot of the
// container currently loaded, and loads the target container's payload.
- (BOOL)switchStorageForBundleID:(NSString *)bundleID
                   fromContainer:(long long)fromContainerID
                     toContainer:(long long)toContainerID
                           error:(NSError *_Nullable *_Nullable)error;
// Drains Instagram and Facebook, then swaps both apps plus shared Meta folders.
- (BOOL)switchPhoneFromContainer:(long long)fromContainerID
                     toContainer:(long long)toContainerID
                           error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteContainerStorage:(long long)containerID error:(NSError *_Nullable *_Nullable)error;
- (NSDictionary *)dataSeparationReportForContainer:(long long)containerID
                                             error:(NSError *_Nullable *_Nullable)error;
// Container whose payload is physically in the live data container, or -1.
- (long long)loadedContainerForBundleID:(NSString *)bundleID error:(NSError *_Nullable *_Nullable)error;
- (BOOL)chownRecursiveToMobileAtPath:(NSString *)path
                               error:(NSError *_Nullable *_Nullable)error;
- (nullable NSDictionary *)dumpKeychainForBundleID:(NSString *)bundleID
                                      containerID:(long long)containerID
                                            error:(NSError *_Nullable *_Nullable)error;
- (BOOL)startLocationAtLatitude:(double)latitude
                     longitude:(double)longitude
                        detail:(NSString *_Nullable *_Nullable)detail
                         error:(NSError *_Nullable *_Nullable)error;
- (BOOL)stopLocationSimulation:(NSError *_Nullable *_Nullable)error;
- (BOOL)clearKeychainForBundleID:(NSString *)bundleID
                         nuclear:(BOOL)nuclear
                           error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
