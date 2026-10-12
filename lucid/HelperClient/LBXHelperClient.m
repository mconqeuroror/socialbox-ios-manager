#import "LBXHelperClient.h"
#import "../Switching/LBXSocialBoxProduct.h"

static NSErrorDomain const LBXClientErrorDomain = @"com.socialbox.helper";

static NSError *LBXClientError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LBXClientErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"helper client error"}];
}

@implementation LBXHelperClient {
    NSXPCConnection *_connection;
    id<LBXHelperProtocol> _proxy;
}

- (void)dealloc {
    [self invalidate];
}

- (BOOL)isConnected {
    return _connection != nil && _proxy != nil;
}

- (void)invalidate {
    [_connection invalidate];
    _connection = nil;
    _proxy = nil;
}

- (BOOL)connect:(NSError **)error {
    if (self.connected) return YES;
    NSXPCConnection *connection =
        [[NSXPCConnection alloc] initWithMachServiceName:@LBX_SOCIALBOX_HELPER_MACH
                                                 options:0];
    if (!connection) {
        if (error) *error = LBXClientError(LBXHelperErrorOperationFailed, @"NSXPCConnection alloc failed");
        return NO;
    }
    connection.remoteObjectInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(LBXHelperProtocol)];
    __weak typeof(self) weakSelf = self;
    connection.invalidationHandler = ^{
        __strong typeof(weakSelf) strong = weakSelf;
        if (!strong) return;
        strong->_connection = nil;
        strong->_proxy = nil;
    };
    connection.interruptionHandler = ^{
        __strong typeof(weakSelf) strong = weakSelf;
        if (!strong) return;
        strong->_connection = nil;
        strong->_proxy = nil;
    };
    [connection resume];
    _connection = connection;
    _proxy = connection.remoteObjectProxy;
    return YES;
}

- (BOOL)ensureConnected:(NSError **)error {
    if (self.connected) return YES;
    return [self connect:error];
}

- (BOOL)runSync:(void (^)(id<LBXHelperProtocol> proxy, dispatch_block_t done))work
          error:(NSError **)error
        timeout:(NSTimeInterval)timeout {
    if (![self ensureConnected:error]) return NO;
    id<LBXHelperProtocol> proxy = _proxy;
    if (!proxy) {
        if (error) *error = LBXClientError(LBXHelperErrorOperationFailed, @"helper proxy missing");
        return NO;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL finished = NO;
    work(proxy, ^{
        finished = YES;
        dispatch_semaphore_signal(sem);
    });
    // NSXPC reply blocks are often delivered on the main queue. Waiting on a
    // semaphore here deadlocks the UI until timeout, so the Location tab
    // never overwrites the last CLI pin and tab switches freeze.
    if ([NSThread isMainThread]) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while (!finished && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
    } else {
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    }
    if (!finished) {
        [self invalidate];
        if (error) *error = LBXClientError(LBXHelperErrorOperationFailed, @"helper XPC timeout");
        return NO;
    }
    return YES;
}

- (BOOL)ping:(NSError **)error {
    __block BOOL alive = NO;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy pingWithReply:^(BOOL value) {
            alive = value;
            done();
        }];
    }
                      error:&local
                    timeout:8.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!alive) {
        if (error) *error = LBXClientError(LBXHelperErrorOperationFailed, @"helper ping returned NO");
        return NO;
    }
    return YES;
}

- (BOOL)killApp:(NSString *)bundleID error:(NSError **)error {
    __block BOOL drained = NO;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy killApp:bundleID reply:^(BOOL value) {
            drained = value;
            done();
        }];
    }
                      error:&local
                    timeout:12.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!drained) {
        if (error) *error = LBXClientError(LBXHelperErrorOperationFailed, @"killApp did not drain");
        return NO;
    }
    return YES;
}

- (BOOL)bootstrapBundleID:(NSString *)bundleID
              containerID:(long long)containerID
                    error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy bootstrapContainerTreeForBundleID:bundleID
                                     containerID:containerID
                                           reply:^(BOOL value, NSError *err) {
                                               success = value;
                                               remote = err;
                                               done();
                                           }];
    }
                      error:&local
                    timeout:20.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"bootstrap failed");
        return NO;
    }
    return YES;
}

- (BOOL)teardownBundleID:(NSString *)bundleID
             containerID:(long long)containerID
                   error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy teardownContainerTreeForBundleID:bundleID
                                    containerID:containerID
                                          reply:^(BOOL value, NSError *err) {
                                              success = value;
                                              remote = err;
                                              done();
                                          }];
    }
                      error:&local
                    timeout:20.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"teardown failed");
        return NO;
    }
    return YES;
}

- (BOOL)atomicBatchSwap:(NSArray<NSDictionary *> *)operations error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy atomicBatchSwap:operations reply:^(BOOL value, NSError *err) {
            success = value;
            remote = err;
            done();
        }];
    }
                      error:&local
                    timeout:30.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"swap failed");
        return NO;
    }
    return YES;
}

- (BOOL)atomicBatchSwapContents:(NSArray<NSDictionary *> *)operations error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy atomicBatchSwapContents:operations reply:^(BOOL value, NSError *err) {
            success = value;
            remote = err;
            done();
        }];
    }
                      error:&local
                    timeout:30.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error)
            *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"contents swap failed");
        return NO;
    }
    return YES;
}

- (BOOL)switchStorageForBundleID:(NSString *)bundleID
                   fromContainer:(long long)fromContainerID
                     toContainer:(long long)toContainerID
                           error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy switchContainerStorageForBundleID:bundleID
                                   fromContainer:fromContainerID
                                     toContainer:toContainerID
                                           reply:^(BOOL value, NSError *err) {
                                               success = value;
                                               remote = err;
                                               done();
                                           }];
    }
                      error:&local
                    timeout:60.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"storage switch failed");
        return NO;
    }
    return YES;
}

- (BOOL)switchPhoneFromContainer:(long long)fromContainerID
                     toContainer:(long long)toContainerID
                           error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy switchPhoneStorageFromContainer:fromContainerID
                                   toContainer:toContainerID
                                         reply:^(BOOL value, NSError *err) {
                                             success = value;
                                             remote = err;
                                             done();
                                         }];
    }
                      error:&local
                    timeout:90.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error)
            *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"phone storage switch failed");
        return NO;
    }
    return YES;
}

- (BOOL)deleteContainerStorage:(long long)containerID error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy deleteContainerStorage:containerID reply:^(BOOL value, NSError *err) {
            success = value;
            remote = err;
            done();
        }];
    }
                      error:&local
                    timeout:30.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error)
            *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"delete container storage failed");
        return NO;
    }
    return YES;
}

- (NSDictionary *)dataSeparationReportForContainer:(long long)containerID error:(NSError **)error {
    __block NSDictionary *report = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy dataSeparationReportForContainer:containerID reply:^(NSDictionary *value) {
            report = value;
            done();
        }];
    }
                      error:&local
                    timeout:15.0];
    if (!ok) {
        if (error) *error = local;
        return nil;
    }
    return report ?: @{};
}

- (long long)loadedContainerForBundleID:(NSString *)bundleID error:(NSError **)error {
    __block long long loaded = -1;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy loadedContainerForBundleID:bundleID reply:^(long long value) {
            loaded = value;
            done();
        }];
    }
                      error:error
                    timeout:8.0];
    return ok ? loaded : -1;
}

- (BOOL)chownRecursiveToMobileAtPath:(NSString *)path error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy chownRecursiveToMobileAtPath:path reply:^(BOOL value, NSError *err) {
            success = value;
            remote = err;
            done();
        }];
    }
                      error:&local
                    timeout:30.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"chown failed");
        return NO;
    }
    return YES;
}

- (NSDictionary *)dumpKeychainForBundleID:(NSString *)bundleID
                              containerID:(long long)containerID
                                    error:(NSError **)error {
    __block NSDictionary *items = nil;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy dumpKeychainForBundleID:bundleID
                           containerID:containerID
                                 reply:^(NSDictionary *value, NSError *err) {
                                     items = value;
                                     remote = err;
                                     done();
                                 }];
    }
                      error:&local
                    timeout:30.0];
    if (!ok) {
        if (error) *error = local;
        return nil;
    }
    if (remote) {
        if (error) *error = remote;
        return nil;
    }
    return items;
}

- (BOOL)clearKeychainForBundleID:(NSString *)bundleID
                         nuclear:(BOOL)nuclear
                           error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy clearKeychainForBundleID:bundleID
                                nuclear:nuclear
                                  reply:^(BOOL value, NSError *err) {
                                      success = value;
                                      remote = err;
                                      done();
                                  }];
    }
                      error:&local
                    timeout:30.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"clearKeychain failed");
        return NO;
    }
    return YES;
}

- (BOOL)startLocationAtLatitude:(double)latitude
                     longitude:(double)longitude
                        detail:(NSString **)detail
                         error:(NSError **)error {
    __block BOOL success = NO;
    __block NSString *remoteDetail = nil;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy startLocationSimulationAtLatitude:latitude
                                      longitude:longitude
                                          reply:^(BOOL value, NSString *text, NSError *err) {
                                              success = value;
                                              remoteDetail = text;
                                              remote = err;
                                              done();
                                          }];
    }
                      error:&local
                    timeout:8.0];
    if (detail) *detail = remoteDetail;
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"location simulation failed");
        return NO;
    }
    return YES;
}

- (BOOL)stopLocationSimulation:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *remote = nil;
    __block NSError *local = nil;
    BOOL ok = [self runSync:^(id<LBXHelperProtocol> proxy, dispatch_block_t done) {
        [proxy stopLocationSimulationWithReply:^(BOOL value, NSString *text, NSError *err) {
            (void)text;
            success = value;
            remote = err;
            done();
        }];
    }
                      error:&local
                    timeout:8.0];
    if (!ok) {
        if (error) *error = local;
        return NO;
    }
    if (!success) {
        if (error) *error = remote ?: LBXClientError(LBXHelperErrorOperationFailed, @"stop location failed");
        return NO;
    }
    return YES;
}

@end
