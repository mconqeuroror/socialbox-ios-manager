#import <Foundation/Foundation.h>
@class RBXOperationContext;

@interface RBXProxyManager : NSObject

// Validate + activate the container's upstream before app launch (R7 preload):
// handshake test + DNS warm + exit-IP geo lookup (for the consistency validator).
- (void)activateProxyForProfile:(NSDictionary *)profile completion:(void (^)(BOOL ok, NSString *exitIP))done;
- (void)activateProxyForProfile:(NSDictionary *)profile context:(RBXOperationContext *)context
    completion:(void (^)(BOOL ok, NSString *exitIP, NSString *message))done;

// Single-link model: load the upstream + rotation endpoint from secure daemon
// config/environment, rotate first, then validate a fresh exit before returning.
- (void)rotateAndActivateProfile:(NSDictionary *)profile
                  previousExitIP:(NSString * _Nullable)previousExitIP
                      generation:(NSString *)generation
                      completion:(void (^)(BOOL ok, NSString * _Nullable exitIP,
                                           NSString * _Nullable message))done;
- (void)rotateAndActivateProfile:(NSDictionary *)profile
                  previousExitIP:(NSString * _Nullable)previousExitIP
                      generation:(NSString *)generation context:(RBXOperationContext *)context
                      completion:(void (^)(BOOL ok, NSString * _Nullable exitIP,
                                           NSString * _Nullable message))done;

// Runs the configured rotation request and validates the resulting proxy exit.
// This never opens a Reddit network lease.
- (void)testCurrentConfiguration:
    (void (^)(NSDictionary *result))done;
- (void)testCurrentConfigurationWithContext:(RBXOperationContext *)context
    completion:(void (^)(NSDictionary *result))done;

// Fresh lookup through the assigned proxy, or the selected device proxy while
// a container is unassigned. Never rotates, assigns, persists or opens a lease.
- (void)detectRegionForContainer:(NSString *)container context:(RBXOperationContext *)context
    completion:(void (^)(NSDictionary *result))done;

// Kill switch teardown (R6): no sockets, DNS flush, route down.
- (void)deactivateProxyForContainer:(NSString *)container;

// Legacy local-profile lookup used only by disabled maintenance code.
- (NSString *)nextUpstreamForContainer:(NSString *)container;
- (NSString *)nextUpstreamForContainer:(NSString *)container error:(NSError **)error;

// Legacy proxy pool migration helpers. Launches do not consume this pool.
// Path: /var/mobile/Library/Preferences/com.redditbox.proxies.plist
// Shape: { "*": [url, ...], "<containerId>": [url, ...] }
+ (NSString *)poolPath;
+ (NSMutableDictionary *)readPool;
+ (NSMutableDictionary *)readPool:(NSError **)error;
+ (void)writePool:(NSDictionary *)pool;
+ (BOOL)writePool:(NSDictionary *)pool error:(NSError **)error;
+ (BOOL)removeUpstreamForContainer:(NSString *)containerId error:(NSError **)error;
+ (void)registerUpstream:(NSString *)url forContainer:(NSString *)containerId;

@end
