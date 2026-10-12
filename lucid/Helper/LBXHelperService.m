#import "LBXHelperService.h"
#import "LBXHelperAdmission.h"
#import "LBXHelperPaths.h"
#import "LBXHelperKeychain.h"
#import "LBXHelperSwap.h"
#import "LBXHelperStorage.h"
#import "LBXHelperLocation.h"
#import "../HelperSafety/LBXDrainClient.h"
#import "../Switching/LBXProcessDrain.h"
#import "../Switching/LBXDarwinDrainBackend.h"
#import "../Switching/LBXManagedApplications.h"
#import "../Switching/LBXSocialBoxProduct.h"
#include <unistd.h>
#include <os/log.h>
#include <string.h>
#include <objc/message.h>

NSErrorDomain const LBXHelperErrorDomain = @"com.socialbox.helper";

@interface NSXPCConnection (LBXHelperAuditToken)
- (audit_token_t)auditToken;
@end

static BOOL LBXConnectionAuditToken(NSXPCConnection *connection, audit_token_t *out) {
    if (!connection || !out) return NO;
    memset(out, 0, sizeof(*out));
    SEL sel = @selector(auditToken);
    if (![connection respondsToSelector:sel]) return NO;
    typedef audit_token_t (*Getter)(id, SEL);
    Getter getter = (Getter)objc_msgSend;
    *out = getter(connection, sel);
    return YES;
}

@implementation LBXHelperService

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    (void)listener;
    audit_token_t token = {0};
    if (!LBXConnectionAuditToken(connection, &token)) {
        os_log_error(OS_LOG_DEFAULT, "SocialBoxHelper missing peer audit token");
        return NO;
    }
    if (!LBXHelperAdmitAuditToken(token)) {
        os_log_error(OS_LOG_DEFAULT, "SocialBoxHelper unauthorized peer euid=%u pid=%u",
                     token.val[1], token.val[5]);
        return NO;
    }
    connection.exportedInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(LBXHelperProtocol)];
    connection.exportedObject = self;
    connection.invalidationHandler = ^{
        os_log(OS_LOG_DEFAULT, "SocialBoxHelper connection invalidated");
    };
    [connection resume];
    return YES;
}

- (void)pingWithReply:(void (^)(BOOL))reply {
    if (reply) reply(YES);
}

- (void)killApp:(NSString *)bundleID reply:(void (^)(BOOL))reply {
    if (!reply) return;
    if (![bundleID isKindOfClass:NSString.class] || !LBXDrainSupportedApplication(bundleID)) {
        reply(NO);
        return;
    }
    if (geteuid() == 0) {
        NSDictionary *receipt =
            LBXDrainApplication([LBXDarwinDrainBackend new], bundleID, NSUUID.UUID.UUIDString, 2.0, YES);
        reply([receipt[@"status"] isEqual:@"observed_absent"]);
        return;
    }
    LBXRequestApplicationDrain(bundleID, ^(BOOL drained) { reply(drained); });
}

- (void)atomicBatchSwap:(NSArray<NSDictionary *> *)operations
                  reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperAtomicBatchSwap(operations, NO, &error);
    reply(ok, error);
}

- (void)atomicBatchSwapContents:(NSArray<NSDictionary *> *)operations
                          reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperAtomicBatchSwap(operations, YES, &error);
    reply(ok, error);
}

- (void)bootstrapContainerTreeForBundleID:(NSString *)bundleID
                              containerID:(long long)containerID
                                    reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperBootstrapContainerTree(bundleID, containerID, &error);
    reply(ok, error);
}

- (void)teardownContainerTreeForBundleID:(NSString *)bundleID
                             containerID:(long long)containerID
                                   reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperTeardownContainerTree(bundleID, containerID, &error);
    reply(ok, error);
}

- (void)dumpKeychainForBundleID:(NSString *)bundleID
                    containerID:(long long)containerID
                          reply:(void (^)(NSDictionary *_Nullable, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    NSDictionary *items = LBXHelperDumpKeychain(bundleID, containerID, &error);
    reply(items, error);
}

- (void)restoreKeychainFromDictionary:(NSDictionary *)items
                          forBundleID:(NSString *)bundleID
                          containerID:(long long)containerID
                                reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperRestoreKeychain(items, bundleID, containerID, &error);
    reply(ok, error);
}

- (void)clearKeychainForBundleID:(NSString *)bundleID
                         nuclear:(BOOL)nuclear
                           reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperClearKeychain(bundleID, nuclear, &error);
    reply(ok, error);
}

- (void)switchContainerStorageForBundleID:(NSString *)bundleID
                            fromContainer:(long long)fromContainerID
                              toContainer:(long long)toContainerID
                                    reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    if (![bundleID isKindOfClass:NSString.class]) {
        reply(NO, [NSError errorWithDomain:LBXHelperErrorDomain code:LBXHelperErrorInvalidArgument
                                  userInfo:@{NSLocalizedDescriptionKey : @"invalid bundle id"}]);
        return;
    }
    // Never move a payload out from under a running app.
    if (geteuid() != 0 ||
        ![LBXDrainApplication([LBXDarwinDrainBackend new], bundleID, NSUUID.UUID.UUIDString, 2.0, YES)[@"status"]
            isEqual:@"observed_absent"]) {
        reply(NO, [NSError errorWithDomain:LBXHelperErrorDomain code:LBXHelperErrorOperationFailed
                                  userInfo:@{NSLocalizedDescriptionKey : @"app did not drain before switch"}]);
        return;
    }
    NSError *error = nil;
    BOOL ok = LBXHelperSwitchContainerStorage(bundleID, fromContainerID, toContainerID, &error);
    os_log(OS_LOG_DEFAULT, "SocialBoxHelper storage switch %{public}@ %lld->%lld ok=%d", bundleID,
           fromContainerID, toContainerID, ok);
    reply(ok, error);
}

- (BOOL)drainBundle:(NSString *)bundleID {
    if (geteuid() != 0) return NO;
    NSDictionary *receipt =
        LBXDrainApplication([LBXDarwinDrainBackend new], bundleID, NSUUID.UUID.UUIDString, 2.0, YES);
    return [receipt[@"status"] isEqual:@"observed_absent"];
}

- (void)switchPhoneStorageFromContainer:(long long)fromContainerID
                            toContainer:(long long)toContainerID
                                  reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    if (![self drainBundle:@"com.burbn.instagram"] || ![self drainBundle:@"com.facebook.Facebook"]) {
        reply(NO, [NSError errorWithDomain:LBXHelperErrorDomain code:LBXHelperErrorOperationFailed
                                  userInfo:@{NSLocalizedDescriptionKey :
                                                 @"Instagram and Facebook did not both drain before switch"}]);
        return;
    }
    NSError *error = nil;
    BOOL ok = LBXHelperSwitchPhoneStorage(fromContainerID, toContainerID, &error);
    os_log(OS_LOG_DEFAULT, "SocialBoxHelper phone switch %lld->%lld ok=%d", fromContainerID, toContainerID, ok);
    reply(ok, error);
}

- (void)deleteContainerStorage:(long long)containerID
                         reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperDeleteContainerStorage(containerID, &error);
    reply(ok, error);
}

- (void)dataSeparationReportForContainer:(long long)containerID reply:(void (^)(NSDictionary *))reply {
    if (!reply) return;
    reply(LBXHelperDataSeparationReport(containerID));
}

- (void)loadedContainerForBundleID:(NSString *)bundleID reply:(void (^)(long long))reply {
    if (!reply) return;
    reply([bundleID isKindOfClass:NSString.class] ? LBXHelperLoadedContainerID(bundleID) : -1);
}

- (void)chownRecursiveToMobileAtPath:(NSString *)path
                               reply:(void (^)(BOOL, NSError *_Nullable))reply {
    if (!reply) return;
    NSError *error = nil;
    BOOL ok = LBXHelperChownRecursiveToMobile(path, &error);
    reply(ok, error);
}

- (void)startLocationSimulationAtLatitude:(double)latitude
                               longitude:(double)longitude
                                   reply:(void (^)(BOOL, NSString *_Nullable, NSError *_Nullable))reply {
    if (!reply) return;
    NSString *detail = nil;
    NSError *error = nil;
    BOOL ok = LBXHelperStartLocationSimulation(latitude, longitude, &detail, &error);
    reply(ok, detail, error);
}

- (void)stopLocationSimulationWithReply:(void (^)(BOOL, NSString *_Nullable, NSError *_Nullable))reply {
    if (!reply) return;
    NSString *detail = nil;
    NSError *error = nil;
    BOOL ok = LBXHelperStopLocationSimulation(&detail, &error);
    reply(ok, detail, error);
}

- (void)issueSandboxExtensionsForContainer:(long long)containerID
                                  bundleID:(NSString *)bundleID
                                     reply:(void (^)(NSArray<NSString *> *_Nullable,
                                                     NSError *_Nullable))reply {
    (void)containerID;
    (void)bundleID;
    if (!reply) return;
    // Honest refusal: sandbox_extension_issue_* is private ABI; do not guess
    // symbol signatures or token formats from decompilation.
    NSError *error = [NSError errorWithDomain:LBXHelperErrorDomain
                                         code:LBXHelperErrorRefused
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"REFUSED: issueSandboxExtensions requires private "
                                             @"sandbox ABI; not implemented in source rebuild"
                                     }];
    reply(nil, error);
}

@end
