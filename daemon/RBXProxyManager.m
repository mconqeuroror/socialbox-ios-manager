#import "RBXHTTPProxy.h"
#import "RBXProxyRouteEvidence.h"
#import "RBXNetworkGate.h"
#import <arpa/inet.h>
#import "RBXProxyManager.h"
#import "RBXCloudSync.h"
#import "RBXSecureConfig.h"
#import "RBXRotationSecrets.h"
#import "RBXProfileIO.h"
#import "RBXContainerRegistry.h"
#import "RBXOperationContext.h"
#import "RBXProxyRegion.h"
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <sys/stat.h>
#import <stdlib.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

// Proxy lifecycle. In v1 the "activation" is:
//  - resolve the container's upstream (from its pool / rotating gateway)
//  - validate: connect through it to a test endpoint, read exit IP
//  - geo-lookup exit IP (feeds validator)
// The generation-bound lease + injected socket guard are the enforcement layer.

static NSString *const kGeoLookup = @"https://ipinfo.io/json";
static NSString *const kProxyPoolPath = @"/var/mobile/Library/Preferences/com.redditbox.proxies.plist";
static NSString *const kRotationConfigPath =
    @"/var/mobile/Library/Preferences/com.redditbox.rotation.plist";

static NSDictionary *RBXDaemonProxyDictionary(NSURL *proxyURL);

static NSError *RBXProxyError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.proxy" code:4
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL RBXProxyCheck(RBXOperationContext *context, NSError **error) {
    if (context.inspectionOnly) {
        if (error) *error = RBXProxyError(@"An inspection operation cannot activate or modify proxy state");
        return NO;
    }
    if (context) return [context check:error];
    if (error) *error = RBXProxyError(@"Proxy work has no operation owner");
    return NO;
}

static RBXOperationContext *RBXProxyLegacyContext(BOOL *owned) {
    RBXOperationContext *context = [RBXOperationContext currentContext];
    *owned = context == nil;
    return context ?: [RBXOperationContext contextWithRequestID:
        [@"proxy-background-" stringByAppendingString:NSUUID.UUID.UUIDString]
        bootEpoch:[RBXOperationContext daemonBootEpoch] timeout:90];
}

@implementation RBXProxyRouteObserver
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics {
    self.verdict = RBXProxyRouteVerdict(metrics.transactionMetrics,self.addresses,self.port);
}
@end

static void RBXProxyRequest(RBXOperationContext *context, NSURLSessionConfiguration *configuration,
    NSMutableURLRequest *request, NSDictionary *proxyEndpoint, void (^done)(NSData *, NSURLResponse *, NSError *)) {
    NSError *error = nil;
    if (!RBXProxyCheck(context, &error)) { if (done) done(nil, nil, error); return; }
    NSTimeInterval budget = MAX(0.001, context.remainingTime);
    request.timeoutInterval = MIN(request.timeoutInterval, budget);
    configuration.timeoutIntervalForRequest = MIN(configuration.timeoutIntervalForRequest, budget);
    configuration.timeoutIntervalForResource = MIN(configuration.timeoutIntervalForResource, budget);
    RBXProxyRouteObserver *route = proxyEndpoint ? [RBXProxyRouteObserver new] : nil;
    if (proxyEndpoint) {
        NSString *host=proxyEndpoint[@"host"];
        route.port=[proxyEndpoint[@"port"] integerValue];
        NSString *url=[NSString stringWithFormat:@"http://%@:%ld",[host containsString:@":"] ? [NSString stringWithFormat:@"[%@]",host] : host,(long)route.port];
        route.addresses=RBXProxyNumericAddress(host) ? @[host] : [RBXNetworkGate proxyAddressesForURL:url];
        if (!route.addresses.count || !RBXProxyCheck(context,&error)) {
            if (done) done(nil,nil,error ?: RBXProxyError(@"Proxy address could not be verified. Container opening is blocked.")); return;
        }
    }
    RBXHTTPProxyDelegate *authentication = proxyEndpoint ?
        [[RBXHTTPProxyDelegate alloc] initWithDelegate:route endpoint:^{
            return [context check:nil] ? proxyEndpoint : nil;
        }] : nil;
    configuration.URLCredentialStorage = nil;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
        delegate:authentication delegateQueue:nil];
    [context trackSession:session];
    __block NSURLSessionDataTask *task = nil;
    task = [session dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *failure) {
        @try {
            [context performBlock:^{
                NSError *ownershipError = nil;
                if (!RBXProxyCheck(context, &ownershipError)) {
                    if (done) done(nil, nil, ownershipError);
                    return;
                }
                NSError *checkedFailure = failure;
                if (!checkedFailure && proxyEndpoint && ![route.verdict isEqual:@"PASS"])
                    checkedFailure = RBXProxyError([route.verdict isEqual:@"LEAK"]
                        ? @"Proxy route leak detected: the health connection did not use the selected proxy address and port. Container opening is blocked."
                        : @"Proxy route could not be verified from network metrics. Container opening is blocked; retry the proxy test.");
                if (done) done(checkedFailure ? nil : data, response, checkedFailure);
            }];
        } @finally {
            [session finishTasksAndInvalidate];
            [context untrackSession:session];
            [context untrackTask:task];
            task = nil;
        }
    }];
    [context trackTask:task];
    if (RBXProxyCheck(context, nil)) [task resume]; else [task cancel];
}

static BOOL RBXProxyProfileAvailable(id containerId, NSError **error) {
    if (![RBXProfileIO isSafeContainerIdentifier:containerId]) {
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain
            code:RBXProfileIOInvalidIdentifier userInfo:@{NSLocalizedDescriptionKey:
                @"Profile identifier is missing or unsafe"}];
        return NO;
    }
    NSDictionary *deletion = [[RBXContainerRegistry new] deletionStateForContainer:containerId];
    if (deletion) {
        if (error) *error = RBXProxyError([deletion[@"message"] isKindOfClass:NSString.class]
            ? deletion[@"message"] : @"Profile is reserved for deletion or recovery");
        return NO;
    }
    return YES;
}

static NSDictionary *RBXProxyCheckedProfile(id profile, NSError **error) {
    if (![profile isKindOfClass:NSDictionary.class] ||
        ![NSJSONSerialization isValidJSONObject:profile]) {
        if (error) *error = RBXProxyError(@"Profile must be a JSON object");
        return nil;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile options:0 error:error];
    return data ? [RBXProfileIO profileDictionaryFromData:data
        containerId:profile[@"containerId"] error:error] : nil;
}

static NSDictionary *RBXProxyLoadProfile(NSString *containerId, NSError **error) {
    if (!RBXProxyProfileAvailable(containerId, error)) return nil;
    return [RBXProfileIO loadProfileForContainer:containerId error:error];
}

static BOOL RBXProxyWriteProfile(NSDictionary *profile, NSError **error) {
    if (!RBXProxyCheck([RBXOperationContext currentContext], error)) return NO;
    if (!RBXProxyCheckedProfile(profile, error)) return NO;
    NSString *containerId = profile[@"containerId"];
    if (!RBXProxyLoadProfile(containerId, error)) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile
        options:NSJSONWritingPrettyPrinted error:error];
    if (!data || !RBXProxyProfileAvailable(containerId, error)) return NO;
    NSString *path = [[@"/var/mobile/Library/Preferences/com.redditbox.profiles"
        stringByAppendingPathComponent:containerId] stringByAppendingPathExtension:@"json"];
    return RBXProxyCheck([RBXOperationContext currentContext], error) &&
        [RBXProfileIO writeProfile:profile containerId:containerId toPath:path error:error];
}

static BOOL RBXProxyStringFields(NSDictionary *dictionary, NSArray *keys, NSError **error) {
    for (NSString *key in keys) {
        if (dictionary[key] && ![dictionary[key] isKindOfClass:NSString.class]) {
            if (error) *error = RBXProxyError([NSString stringWithFormat:
                @"Proxy configuration field '%@' must be a string", key]);
            return NO;
        }
    }
    return YES;
}

static BOOL RBXProxyPoolValid(id pool, NSError **error) {
    if (![pool isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXProxyError(@"Proxy pool root must be a dictionary");
        return NO;
    }
    for (id key in pool) {
        if (![key isKindOfClass:NSString.class] ||
            (![key isEqualToString:@"*"] && ![RBXProfileIO isSafeContainerIdentifier:key]) ||
            ![pool[key] isKindOfClass:NSArray.class]) {
            if (error) *error = RBXProxyError(@"Proxy pool contains an invalid identifier or URL list");
            return NO;
        }
        for (id url in pool[key]) {
            if (![url isKindOfClass:NSString.class] || ![url length]) {
                if (error) *error = RBXProxyError(@"Proxy pool URLs must be nonempty strings");
                return NO;
            }
        }
    }
    return YES;
}

static NSString *RBXEnvironmentString(const char *name) {
    const char *value = getenv(name);
    return value && value[0] ? [NSString stringWithUTF8String:value] : nil;
}

static NSDictionary *RBXRotationConfiguration(NSDictionary *profile, NSError **error) {
    if (![profile isKindOfClass:NSDictionary.class] ||
        (profile[@"proxy"] && ![profile[@"proxy"] isKindOfClass:NSDictionary.class])) {
        if (error && !*error) *error = RBXProxyError(@"Profile proxy section must be an object");
        return nil;
    }
    NSString *proxyURL = RBXEnvironmentString("RBX_PROXY_URL");
    NSString *rotationURL = RBXEnvironmentString("RBX_ROTATION_URL");
    NSString *authorization = RBXEnvironmentString("RBX_ROTATION_AUTHORIZATION");
    NSString *authHeader = RBXEnvironmentString("RBX_ROTATION_AUTH_HEADER") ?: @"Authorization";
    NSString *method = RBXEnvironmentString("RBX_ROTATION_METHOD");

    // Launcher/cloud configuration is protected by the shared Keychain access
    // group and always overrides development environment/plist fallbacks.
    NSError *secureError = nil;
    NSDictionary *secure = [RBXSecureConfig rotationConfiguration:&secureError];
    if (secureError) {
        if (error) *error = secureError;
        return nil;
    }
    if ([secure[@"proxyDisabled"] boolValue]) {
        if (error) *error = RBXProxyError(@"Choose a saved proxy in Proxies before connecting.");
        return nil;
    }
    NSArray *configKeys = @[@"proxyURL", @"rotationURL", @"authorization", @"authHeader", @"method"];
    if (secure && (![secure isKindOfClass:NSDictionary.class] ||
        !RBXProxyStringFields(secure, configKeys, error))) {
        if (error && !*error) *error = RBXProxyError(@"Secure rotation configuration must be a dictionary");
        return nil;
    }
    if (secure) {
        if ([secure[@"proxyURL"] isKindOfClass:[NSString class]] &&
            [secure[@"proxyURL"] length]) {
            proxyURL = secure[@"proxyURL"];
            // A saved proxy owns its optional rotation link, including an
            // explicit empty link. Never resurrect a development fallback.
            rotationURL = secure[@"rotationURL"] ?: @"";
        } else if ([secure[@"rotationURL"] length]) rotationURL = secure[@"rotationURL"];
        if ([secure[@"authorization"] isKindOfClass:[NSString class]])
            authorization = secure[@"authorization"];
        if ([secure[@"authHeader"] isKindOfClass:[NSString class]] &&
            [secure[@"authHeader"] length]) authHeader = secure[@"authHeader"];
        if ([secure[@"method"] isKindOfClass:[NSString class]] &&
            [secure[@"method"] length]) method = secure[@"method"];
    }

    if (!proxyURL.length) {
        struct stat info = {};
        if (stat(kRotationConfigPath.fileSystemRepresentation, &info) != 0 ||
            info.st_uid != 0 || (info.st_mode & 0022) != 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.redditbox.rotation" code:1
                                         userInfo:@{NSLocalizedDescriptionKey:
                    @"rotation config must be root-owned and not group/world writable"}];
            }
            return nil;
        }
        NSData *fileData = [NSData dataWithContentsOfFile:kRotationConfigPath options:0 error:error];
        if (!fileData) return nil;
        if (!fileData.length) {
            if (error) *error = RBXProxyError(@"Rotation configuration file is empty");
            return nil;
        }
        id file = [NSPropertyListSerialization propertyListWithData:fileData options:0 format:NULL error:error];
        if (!file) return nil;
        if (![file isKindOfClass:NSDictionary.class] || !RBXProxyStringFields(file, configKeys, error)) {
            if (error && !*error) *error = RBXProxyError(@"Rotation configuration root must be a dictionary");
            return nil;
        }
        if (!proxyURL.length && [file[@"proxyURL"] isKindOfClass:[NSString class]])
            proxyURL = file[@"proxyURL"];
        if (!rotationURL.length && [file[@"rotationURL"] isKindOfClass:[NSString class]])
            rotationURL = file[@"rotationURL"];
        if (![secure[@"authorization"] isKindOfClass:NSString.class] &&
            !authorization.length && [file[@"authorization"] isKindOfClass:[NSString class]])
            authorization = file[@"authorization"];
        if ([file[@"authHeader"] isKindOfClass:[NSString class]] &&
            !([secure[@"authHeader"] isKindOfClass:NSString.class] && [secure[@"authHeader"] length]) &&
            !RBXEnvironmentString("RBX_ROTATION_AUTH_HEADER").length)
            authHeader = file[@"authHeader"];
        if (!method.length && [file[@"method"] isKindOfClass:[NSString class]])
            method = file[@"method"];
    }

    NSError *overrideError = nil;
    NSDictionary *override = profile[@"containerId"] ?
        [RBXRotationSecrets overrideForProfile:profile[@"containerId"] error:&overrideError] : nil;
    if (overrideError) { if (error) *error = overrideError; return nil; }
    if (override.count) {
        authHeader = override[@"header"];
        authorization = override[@"value"];
    }

    if (!proxyURL.length) {
        if (error) *error = RBXProxyError(@"Add a proxy in the Proxies tab");
        return nil;
    }
    NSURL *proxy = [NSURL URLWithString:proxyURL];
    NSURL *rotation = [NSURL URLWithString:rotationURL];
    NSString *normalizedMethod = method.uppercaseString ?: @"POST";
    BOOL methodValid = [@[@"GET", @"POST"] containsObject:normalizedMethod];
    BOOL rotationTLS = [rotation.scheme.lowercaseString isEqualToString:@"https"];
    NSCharacterSet *invalidHeader = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"]
        invertedSet];
    if (!RBXDaemonProxyDictionary(proxy) || (rotationURL.length &&
        (!rotation.host.length || rotation.user.length || rotation.password.length ||
         rotation.fragment.length || !rotationTLS || !methodValid))) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox.rotation" code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                @"invalid proxy or HTTPS rotation configuration"}];
        }
        return nil;
    }
    if (!authHeader.length || authHeader.length > 128 ||
        [authHeader rangeOfCharacterFromSet:invalidHeader].location != NSNotFound ||
        authorization.length > 4096) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.rotation" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"invalid rotation authentication header"}];
        return nil;
    }
    NSMutableDictionary *config = [@{
        @"proxyURL": proxyURL,
        @"rotationURL": rotationURL ?: @"",
        @"method": normalizedMethod,
    } mutableCopy];
    if (authorization.length) {
        config[@"authorization"] = authorization;
        config[@"authHeader"] = authHeader;
    }
    return config;
}

static NSDictionary *RBXDaemonProxyDictionary(NSURL *proxyURL) {
    NSDictionary *endpoint = RBXParseHTTPProxyURL(proxyURL.absoluteString);
    return endpoint ? RBXHTTPProxySettings(endpoint) : nil;
}

@interface RBXProxyManager ()
- (void)_activateProxyForProfile:(NSDictionary *)profile persistProfile:(BOOL)persist
    context:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *, NSError *))done;
- (void)_removeCacheForContainer:(NSString *)container context:(RBXOperationContext *)context;
@end

@implementation RBXProxyManager {
    NSMutableDictionary<NSString *, NSString *> *_activeUpstream;
    NSMutableDictionary<NSString *, NSString *> *_activeOperationTokens;
}

- (void)detectRegionForContainer:(NSString *)container context:(RBXOperationContext *)context
    completion:(void (^)(NSDictionary *))done {
    void (^fail)(NSString *) = ^(NSString *message) { if (done) done(@{@"ok":@NO, @"message":message ?: @"Proxy region lookup failed."}); };
    NSError *error = nil;
    if (!RBXProxyCheck(context, &error)) { fail(@"Proxy lookup requires a current operation."); return; }
    NSDictionary *profile = container.length ? RBXProxyLoadProfile(container, &error) : nil;
    if (container.length && !profile) { fail(error.localizedDescription); return; }
    NSDictionary *editor = container.length ? [[RBXContainerRegistry new] identityEditorStateForContainer:container error:&error] : nil;
    if (container.length && (!editor || [editor[@"locked"] boolValue])) { fail(@"This container's identity is locked after first use. Its region will not be changed."); return; }
    NSString *assigned = profile[@"proxy"][@"url"];
    BOOL useAssigned = assigned.length > 0;
    NSString *url = useAssigned ? assigned : RBXRotationConfiguration(@{}, &error)[@"proxyURL"];
    NSDictionary *endpoint = RBXParseHTTPProxyURL(url);
    if (!endpoint) { fail(error.localizedDescription ?: @"Select a valid proxy in Proxies first."); return; }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.connectionProxyDictionary = RBXHTTPProxySettings(endpoint);
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = 30;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGeoLookup]];
    request.timeoutInterval = 20;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    RBXProxyRequest(context, configuration, request, endpoint, ^(NSData *data, NSURLResponse *response, NSError *failure) {
        if (failure || ![response isKindOfClass:NSHTTPURLResponse.class] ||
            [(NSHTTPURLResponse *)response statusCode] != 200 || !data.length || data.length > 65536) {
            fail(@"Could not detect the proxy region. Check the proxy connection and retry; existing values were kept."); return;
        }
        NSError *parseError = nil;
        NSDictionary *region = RBXProxyRegionSuggestion([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], &parseError);
        if (!region) { fail(parseError.localizedDescription); return; }
        NSDictionary *current = container.length ? RBXProxyLoadProfile(container, &parseError) : nil;
        if (container.length && !current) { fail(@"Container changed during lookup. Reload and retry."); return; }
        NSString *currentAssigned = current[@"proxy"][@"url"] ?: @"";
        NSString *currentURL = useAssigned ? currentAssigned : RBXRotationConfiguration(@{}, &parseError)[@"proxyURL"];
        if (![currentURL isEqual:url] || (!useAssigned && currentAssigned.length)) {
            fail(@"Proxy selection changed during lookup. Retry with the current proxy."); return;
        }
        if (useAssigned && ![region[@"country"] isEqual:current[@"proxy"][@"country"]]) {
            fail(@"The live proxy country differs from this container's cloud assignment. Correct the assignment or proxy before changing its region."); return;
        }
        NSMutableDictionary *result = [region mutableCopy];
        result[@"ok"] = @YES;
        result[@"proxySource"] = useAssigned ? @"assigned" : @"selected-device";
        result[@"message"] = @"Region detected. Carrier and language are suggested profile values, not detected SIM settings.";
        // Allowlisted geography only. The URL, credentials, IP and identifiers
        // never enter this result or a durable public receipt.
        if (done) done(result);
    });
}

+ (NSString *)poolPath {
    return kProxyPoolPath;
}

+ (NSMutableDictionary *)readPool {
    NSError *error = nil;
    NSMutableDictionary *pool = [self readPool:&error];
    if (!pool) NSLog(@"redditboxd: proxy pool read failed: %@", error.localizedDescription);
    return pool;
}

+ (NSMutableDictionary *)readPool:(NSError **)error {
    struct stat info;
    if (lstat(kProxyPoolPath.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) return [NSMutableDictionary dictionary];
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_nlink != 1) {
        if (error) *error = RBXProxyError(@"Proxy pool is not a regular file");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:kProxyPoolPath options:0 error:error];
    if (!data) return nil;
    if (!data.length) {
        if (error) *error = RBXProxyError(@"Proxy pool file is empty");
        return nil;
    }
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListMutableContainers format:NULL error:error];
    return value && RBXProxyPoolValid(value, error) ? [value mutableCopy] : nil;
}

+ (void)writePool:(NSDictionary *)pool {
    NSError *error = nil;
    if (![self writePool:pool error:&error])
        NSLog(@"redditboxd: proxy pool publication failed: %@", error.localizedDescription);
}

+ (BOOL)writePool:(NSDictionary *)pool error:(NSError **)error {
    if (!RBXProxyCheck([RBXOperationContext currentContext], error)) return NO;
    @synchronized (self) {
        if (!RBXProxyPoolValid(pool, error)) return NO;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:pool
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        if (!data || ![data writeToFile:kProxyPoolPath options:NSDataWritingAtomic error:error]) return NO;
        int file = open(kProxyPoolPath.fileSystemRepresentation, O_RDWR | O_NOFOLLOW);
        BOOL durable = file >= 0 && fsync(file) == 0;
        if (file >= 0) close(file);
        int parent = open(kProxyPoolPath.stringByDeletingLastPathComponent.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        durable = durable && parent >= 0 && fsync(parent) == 0;
        if (parent >= 0) close(parent);
        NSData *published = durable ? [NSData dataWithContentsOfFile:kProxyPoolPath options:0 error:error] : nil;
        if (!durable || ![published isEqualToData:data]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.proxy" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Proxy pool durability or read-back verification failed; retry deletion"}];
            return NO;
        }
        return YES;
    }
}

+ (BOOL)removeUpstreamForContainer:(NSString *)containerId error:(NSError **)error {
    if (!RBXProxyCheck([RBXOperationContext currentContext], error)) return NO;
    if (![RBXProfileIO isSafeContainerIdentifier:containerId]) {
        if (error) *error = RBXProxyError(@"Profile identifier is missing or unsafe");
        return NO;
    }
    @synchronized (self) {
        struct stat info;
        if (lstat(kProxyPoolPath.fileSystemRepresentation, &info) != 0) {
            if (errno == ENOENT) return YES;
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
        if (!S_ISREG(info.st_mode) || info.st_nlink != 1) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.proxy" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Proxy pool is not a regular file"}];
            return NO;
        }
        NSData *data = [NSData dataWithContentsOfFile:kProxyPoolPath options:0 error:error];
        if (!data) return NO;
        id value = data.length ? [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListMutableContainers format:NULL error:error] : nil;
        if (![value isKindOfClass:NSMutableDictionary.class]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.proxy" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Proxy pool is empty or corrupt; repair it before retrying deletion"}];
            return NO;
        }
        NSMutableDictionary *pool = value;
        [pool removeObjectForKey:containerId];
        return [self writePool:pool error:error];
    }
}

+ (void)registerUpstream:(NSString *)url forContainer:(NSString *)containerId {
    if (!RBXProxyCheck([RBXOperationContext currentContext], nil)) return;
    if (![url isKindOfClass:NSString.class] || !url.length ||
        (containerId && ![containerId isKindOfClass:NSString.class])) return;
    NSError *error = nil;
    if (containerId.length && !RBXProxyProfileAvailable(containerId, &error)) {
        NSLog(@"redditboxd: proxy registration refused: %@", error.localizedDescription);
        return;
    }
    NSString *key = containerId.length ? containerId : @"*";
    NSMutableDictionary *pool = [self readPool:&error];
    if (!pool) {
        NSLog(@"redditboxd: proxy registration failed: %@", error.localizedDescription);
        return;
    }
    NSMutableArray *list = [pool[key] isKindOfClass:[NSArray class]] ? [pool[key] mutableCopy] : [NSMutableArray array];
    if (![list containsObject:url]) [list addObject:url];
    pool[key] = list;
    [self writePool:pool];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeUpstream = [NSMutableDictionary dictionary];
        _activeOperationTokens = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)nextUpstreamForContainer:(NSString *)container {
    NSError *error = nil;
    NSString *upstream = [self nextUpstreamForContainer:container error:&error];
    if (error) NSLog(@"redditboxd: proxy lookup failed: %@", error.localizedDescription);
    return upstream;
}

- (NSString *)nextUpstreamForContainer:(NSString *)container error:(NSError **)error {
    RBXOperationContext *context = [RBXOperationContext currentContext];
    if (!RBXProxyCheck(context, error)) return nil;
    // The profile is cloud-sync authoritative; re-read it so independent manager
    // instances cannot retain an endpoint after explicit reassignment/reset.
    NSDictionary *profile = RBXProxyLoadProfile(container, error);
    if (!profile) {
        if ([RBXProfileIO isSafeContainerIdentifier:container]) [self _removeCacheForContainer:container context:context];
        return nil;
    }
    NSString *profileURL = [profile[@"proxy"][@"url"] isKindOfClass:[NSString class]]
        ? profile[@"proxy"][@"url"] : nil;
    if (profileURL.length) {
        @synchronized (self) {
            if (!RBXProxyCheck(context, error)) return nil;
            _activeUpstream[container] = profileURL;
            _activeOperationTokens[container] = context.token;
        }
        return profileURL;
    }
    [self _removeCacheForContainer:container context:context];
    if (error) *error = RBXProxyError(@"Profile has no assigned proxy URL");
    // Never select a random/global fallback. Assignment must be explicit and sticky.
    return nil;
}

- (void)rotateAndActivateProfile:(NSDictionary *)profile
                  previousExitIP:(NSString *)previousExitIP
                      generation:(NSString *)generation
                      completion:(void (^)(BOOL, NSString *, NSString *))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXProxyLegacyContext(&owned);
    dispatch_block_t start = ^{
        [self rotateAndActivateProfile:profile previousExitIP:previousExitIP generation:generation
            context:context completion:done];
    };
    if (owned) {
        if (![context dispatchAsyncOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) block:start]) {
            NSError *error = nil; RBXProxyCheck(context, &error);
            if (done) done(NO, nil, error.localizedDescription);
        }
    } else start();
    if (owned) [context finishWhenQuiescent];
}

- (void)rotateAndActivateProfile:(NSDictionary *)profile
                  previousExitIP:(NSString *)previousExitIP
                      generation:(NSString *)generation context:(RBXOperationContext *)context
                      completion:(void (^)(BOOL, NSString *, NSString *))done {
    NSError *ownershipError = nil;
    if (!RBXProxyCheck(context, &ownershipError)) { if (done) done(NO, nil, ownershipError.localizedDescription); return; }
    NSError *configError = nil;
    NSDictionary *checked = RBXProxyCheckedProfile(profile, &configError);
    if (!checked || !RBXProxyLoadProfile(checked[@"containerId"], &configError)) {
        if (done) done(NO, nil, configError.localizedDescription);
        return;
    }
    if (![generation isKindOfClass:NSString.class] || !generation.length ||
        (previousExitIP && ![previousExitIP isKindOfClass:NSString.class])) {
        if (done) done(NO, nil, @"Rotation generation or previous exit IP has an invalid type");
        return;
    }
    profile = checked;
    NSDictionary *config = RBXRotationConfiguration(profile, &configError);
    if (!config) {
        if (done) done(NO, nil, configError.localizedDescription);
        return;
    }

    if (![config[@"rotationURL"] length]) {
        // Static proxy mode still performs proxy health verification and uses
        // the caller's unchanged CLOSED/lease/managed-installation sequence.
        NSMutableDictionary *staticProfile = [profile mutableCopy];
        NSMutableDictionary *proxy = [profile[@"proxy"] mutableCopy] ?: [NSMutableDictionary dictionary];
        proxy[@"url"] = config[@"proxyURL"];
        [proxy removeObjectForKey:@"proxyId"];
        staticProfile[@"proxy"] = proxy;
        [self _activateProxyForProfile:staticProfile persistProfile:YES context:context
            completion:^(BOOL ok, NSString *exitIP, NSError *error) {
                if (done) done(ok, exitIP, error.localizedDescription);
            }];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:config[@"rotationURL"]]];
    request.HTTPMethod = config[@"method"];
    request.timeoutInterval = 30;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if ([config[@"authorization"] length]) {
        [request setValue:config[@"authorization"] forHTTPHeaderField:config[@"authHeader"]];
    }
    NSLog(@"redditboxd: ROTATION CALLED generation=%@",
          [generation substringToIndex:MIN((NSUInteger)8, generation.length)]);

    NSURLSessionConfiguration *rotationSessionConfig =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    RBXProxyRequest(context, rotationSessionConfig, request, nil,
        ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300) {
            if (done) done(NO, nil, error.localizedDescription ?:
                           [NSString stringWithFormat:@"rotation HTTP %ld", (long)status]);
            return;
        }
        NSLog(@"redditboxd: ROTATION ACKNOWLEDGED generation=%@",
              [generation substringToIndex:MIN((NSUInteger)8, generation.length)]);

        NSLog(@"redditboxd: rotation propagation quarantine started");
        BOOL scheduled = [context dispatchAfter:2 queue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) block:^{
            NSError *ownershipError = nil;
            if (!RBXProxyCheck(context, &ownershipError)) {
                if (done) done(NO, nil, ownershipError.localizedDescription);
                return;
            }
            NSMutableDictionary *rotatedProfile = [profile mutableCopy];
            NSMutableDictionary *proxy =
                [profile[@"proxy"] isKindOfClass:[NSDictionary class]]
                    ? [profile[@"proxy"] mutableCopy] : [NSMutableDictionary dictionary];
            proxy[@"url"] = config[@"proxyURL"];
            [proxy removeObjectForKey:@"proxyId"];
            rotatedProfile[@"proxy"] = proxy;

            [self _activateProxyForProfile:rotatedProfile persistProfile:YES context:context
                completion:^(BOOL ok, NSString *exitIP, NSError *activationError) {
                if (!ok) {
                    if (done) done(NO, nil, activationError.localizedDescription ?: @"rotated proxy validation failed");
                    return;
                }
                if (previousExitIP.length && [previousExitIP isEqualToString:exitIP]) {
                    if (done) done(NO, nil, @"rotation did not produce a fresh exit IP");
                    return;
                }
                NSLog(@"redditboxd: FRESH IP APPLIED generation=%@",
                      [generation substringToIndex:MIN((NSUInteger)8, generation.length)]);
                if (done) done(YES, exitIP, nil);
            }];
        }];
        if (!scheduled) {
            NSError *ownershipError = nil;
            RBXProxyCheck(context, &ownershipError);
            if (done) done(NO, nil, ownershipError.localizedDescription ?: @"Rotation quarantine could not be scheduled");
        }
    });
}

- (void)testCurrentConfiguration:(void (^)(NSDictionary *result))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXProxyLegacyContext(&owned);
    dispatch_block_t start = ^{ [self testCurrentConfigurationWithContext:context completion:done]; };
    if (owned) {
        if (![context dispatchAsyncOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) block:start]) {
            NSError *error = nil; RBXProxyCheck(context, &error);
            if (done) done(@{@"ok": @NO, @"message": error.localizedDescription ?: @"Proxy test could not start"});
        }
    } else start();
    if (owned) [context finishWhenQuiescent];
}

- (void)testCurrentConfigurationWithContext:(RBXOperationContext *)context
    completion:(void (^)(NSDictionary *result))done {
    NSError *ownershipError = nil;
    if (!RBXProxyCheck(context, &ownershipError)) {
        if (done) done(@{@"ok": @NO, @"message": ownershipError.localizedDescription});
        return;
    }
    NSError *configError = nil;
    NSDictionary *config = RBXRotationConfiguration(@{}, &configError);
    if (!config) {
        if (done) done(@{@"ok": @NO, @"message":
            configError.localizedDescription ?: @"Configuration is invalid",
            @"testedAt": @(NSDate.date.timeIntervalSince1970)});
        return;
    }
    if (![config[@"rotationURL"] length]) {
        NSDictionary *testProfile = @{@"containerId": @"__configuration_test__",
            @"proxy": @{@"url": config[@"proxyURL"]}};
        [self _activateProxyForProfile:testProfile persistProfile:NO context:context
            completion:^(BOOL ok, NSString *exitIP, NSError *error) {
                [self _removeCacheForContainer:@"__configuration_test__" context:context];
                if (done) done(@{@"ok": @(ok), @"rotationSkipped": @YES,
                    @"proxyStatus": ok ? @"healthy" : @"unhealthy", @"exitIP": exitIP ?: @"",
                    @"message": ok ? @"Proxy connected. No rotation link configured." :
                        (error.localizedDescription ?: @"Proxy connection failed"),
                    @"testedAt": @(NSDate.date.timeIntervalSince1970)});
            }];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:config[@"rotationURL"]]];
    request.HTTPMethod = config[@"method"];
    request.timeoutInterval = 20;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if ([config[@"authorization"] length]) {
        [request setValue:config[@"authorization"]
       forHTTPHeaderField:config[@"authHeader"]];
    }
    RBXProxyRequest(context, NSURLSessionConfiguration.ephemeralSessionConfiguration, request, nil,
      ^(NSData *data, NSURLResponse *response, NSError *requestError) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (requestError || status < 200 || status >= 300) {
            if (done) done(@{
                @"ok": @NO,
                @"rotationStatus": @(status),
                @"message": requestError.localizedDescription ?:
                    [NSString stringWithFormat:@"Rotation returned HTTP %ld", (long)status],
                @"testedAt": @(NSDate.date.timeIntervalSince1970),
            });
            return;
        }
        NSDictionary *testProfile = @{
            @"containerId": @"__configuration_test__",
            @"proxy": @{@"url": config[@"proxyURL"]},
        };
        [self _activateProxyForProfile:testProfile persistProfile:NO context:context
            completion:^(BOOL ok, NSString *exitIP, NSError *activationError) {
            [self _removeCacheForContainer:@"__configuration_test__" context:context];
            if (done) done(@{
                @"ok": @(ok),
                @"rotationStatus": @(status),
                @"proxyStatus": ok ? @"healthy" : @"unhealthy",
                @"exitIP": exitIP ?: @"",
                @"message": ok ? @"Rotation and proxy connection succeeded" :
                    (activationError.localizedDescription ?: @"Rotation succeeded, but proxy validation failed"),
                @"testedAt": @(NSDate.date.timeIntervalSince1970),
            });
        }];
    });
}

- (void)activateProxyForProfile:(NSDictionary *)profile completion:(void (^)(BOOL, NSString *))done {
    BOOL owned = NO;
    RBXOperationContext *context = RBXProxyLegacyContext(&owned);
    dispatch_block_t start = ^{
        [self activateProxyForProfile:profile context:context completion:^(BOOL ok, NSString *exitIP, NSString *message) {
            if (!ok) NSLog(@"redditboxd: proxy activation failed: %@", message);
            if (done) done(ok, exitIP);
        }];
    };
    if (owned) {
        if (![context dispatchAsyncOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) block:start] && done)
            done(NO, nil);
    } else start();
    if (owned) [context finishWhenQuiescent];
}

- (void)activateProxyForProfile:(NSDictionary *)profile context:(RBXOperationContext *)context
    completion:(void (^)(BOOL, NSString *, NSString *))done {
    [self _activateProxyForProfile:profile persistProfile:YES context:context
        completion:^(BOOL ok, NSString *exitIP, NSError *error) {
        if (done) done(ok, exitIP, error.localizedDescription);
    }];
}

- (void)_activateProxyForProfile:(NSDictionary *)profile persistProfile:(BOOL)persist
    context:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *, NSError *))done {
    NSError *profileError = nil;
    if (!RBXProxyCheck(context, &profileError)) { if (done) done(NO, nil, profileError); return; }
    NSDictionary *checked = RBXProxyCheckedProfile(profile, &profileError);
    if (!checked || (persist && !RBXProxyLoadProfile(checked[@"containerId"], &profileError))) {
        if (done) done(NO, nil, profileError);
        return;
    }
    profile = checked;
    NSString *container = profile[@"containerId"];
    NSString *proxyId = profile[@"proxy"][@"proxyId"];
    NSString *upstream = profile[@"proxy"][@"url"];
    if (!upstream.length) {
        if (done) done(NO, nil, RBXProxyError(@"Profile has no assigned proxy URL"));
        return;
    }

    NSURL *proxyURL = [NSURL URLWithString:upstream];
    NSDictionary *proxyDictionary = proxyURL ? RBXDaemonProxyDictionary(proxyURL) : nil;
    if (!proxyDictionary) {
        if (done) done(NO, nil, RBXProxyError(@"Assigned proxy URL is invalid or unsupported"));
        return;
    }
    @synchronized (self) {
        if (!RBXProxyCheck(context, &profileError)) { if (done) done(NO, nil, profileError); return; }
        _activeUpstream[container] = upstream;
        _activeOperationTokens[container] = context.token;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30;
    cfg.timeoutIntervalForResource = 45;
    cfg.connectionProxyDictionary = proxyDictionary;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGeoLookup]];
    RBXProxyRequest(context, cfg, request, RBXParseHTTPProxyURL(upstream), ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSError *validationError = err;
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (!validationError && (status < 200 || status >= 300))
            validationError = RBXProxyError([NSString stringWithFormat:@"Proxy health check returned HTTP %ld", (long)status]);
        if (!validationError && !data.length) validationError = RBXProxyError(@"Proxy health response is empty");
        id info = validationError ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:&validationError];
        if (!validationError && ![info isKindOfClass:NSDictionary.class])
            validationError = RBXProxyError(@"Proxy health response must be a JSON object");
        if (!validationError && (![info[@"ip"] isKindOfClass:NSString.class] ||
            ![info[@"country"] isKindOfClass:NSString.class]))
            validationError = RBXProxyError(@"Proxy health response must contain string IP and country fields");
        NSString *exitIP = validationError ? nil : info[@"ip"];
        NSString *country = validationError ? nil : info[@"country"];
        struct in_addr ipv4; struct in6_addr ipv6;
        if (!validationError && (!exitIP.length ||
            (inet_pton(AF_INET,exitIP.UTF8String,&ipv4) != 1 && inet_pton(AF_INET6,exitIP.UTF8String,&ipv6) != 1)))
            validationError = RBXProxyError(@"Proxy returned no valid numeric exit IP");
        if (validationError) {
            [[RBXCloudSync sharedSync] reportProxyId:proxyId healthy:NO
                message:validationError.localizedDescription context:context];
            if (done) done(NO, nil, validationError);
            return;
        }
        NSString *expectedCountry = profile[@"proxy"][@"country"];
        BOOL geoConsistent = country.length > 0 &&
            (!expectedCountry.length || [country isEqualToString:expectedCountry]);
        NSMutableDictionary *updated = [profile mutableCopy];
        NSMutableDictionary *validation = [@{
            @"proxyCountry": expectedCountry ?: country,
            @"observedProxyCountry": country,
            @"geoConsistent": @(geoConsistent),
            @"exitIP": exitIP,
            @"proxyHealthy": @(geoConsistent),
            @"checkedAt": @(NSDate.date.timeIntervalSince1970),
        } mutableCopy];
        if (!geoConsistent) validation[@"message"] =
            @"Live proxy exit country does not match the configured identity country";
        updated[@"validation"] = validation;
        // Configuration testing has no persisted profile. Real activation must
        // still have a readable, unreserved profile when its network reply arrives.
        NSError *writeError = nil;
        if (persist && !RBXProxyWriteProfile(updated, &writeError)) {
            if (done) done(NO, nil, writeError);
            return;
        }
        [[RBXCloudSync sharedSync] reportProxyId:proxyId healthy:geoConsistent
            message:geoConsistent ? @"Reachable" : @"Proxy country does not match profile" context:context];
        if (done) done(geoConsistent, geoConsistent ? exitIP : nil,
            geoConsistent ? nil : RBXProxyError(@"Proxy country does not match profile"));
    });
}

- (void)_removeCacheForContainer:(NSString *)container context:(RBXOperationContext *)context {
    @synchronized (self) {
        if (!RBXProxyCheck(context, nil) || ![_activeOperationTokens[container] isEqualToString:context.token]) return;
        [_activeUpstream removeObjectForKey:container];
        [_activeOperationTokens removeObjectForKey:container];
    }
}

- (void)deactivateProxyForContainer:(NSString *)container {
    if (![RBXProfileIO isSafeContainerIdentifier:container]) return;
    RBXOperationContext *context = [RBXOperationContext currentContext];
    @synchronized (self) {
        // Revocation removes cached state and is safe outside a request.
        if (context && !RBXProxyCheck(context, nil)) return;
        [_activeUpstream removeObjectForKey:container];
        [_activeOperationTokens removeObjectForKey:container];
    }
    NSLog(@"redditboxd: proxy session state cleared for container %@", container ?: @"");
}

@end
