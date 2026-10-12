#import "LBXProxyInput.h"
#import "../../shared/RBXHTTPProxy.h"
#import <objc/runtime.h>
#import <dlfcn.h>

@interface LBXProxyInputPlan ()
@property(nonatomic, readwrite) BOOL useOriginalInput;
@property(nonatomic, readwrite, copy) NSString *issue;
@property(nonatomic, readwrite, copy) NSArray<NSDictionary *> *endpoints;
@property(nonatomic) NSUInteger duplicates;
- (instancetype)initPrivate;
@end
@implementation LBXProxyInputPlan
- (instancetype)initPrivate { if ((self=[super init])) _endpoints=@[]; return self; }
- (NSDictionary *)safeStatus { return @{@"inputStatus":self.issue?@"invalid":(self.useOriginalInput?@"original-handler":@"prepared"),@"endpointCount":@(self.endpoints.count),@"duplicateCount":@(self.duplicates),@"connectionTested":@NO}; }
- (NSString *)description { return self.safeStatus.description; }
- (NSString *)debugDescription { return self.description; }
@end
static NSString *Trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
static NSTextCheckingResult *Match(NSString *s,NSString *pattern) {
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m=[re firstMatchInString:s options:0 range:NSMakeRange(0,s.length)];
    return m&&NSEqualRanges(m.range,NSMakeRange(0,s.length))?m:nil;
}
static NSString *Group(NSString *s,NSTextCheckingResult *m,NSUInteger i) { NSRange r=[m rangeAtIndex:i];return r.location==NSNotFound?nil:[s substringWithRange:r]; }
static NSString *Encode(NSString *s) { return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]]; }
static NSDictionary *Endpoint(NSString *line, BOOL *original) {
    *original=NO;
    NSString *protocol=nil,*body=line;
    NSTextCheckingResult *prefix=Match(line,@"(HTTP|HTTPS|SOCKS5|SOCKS)[ \\t]+(.+)");
    if (prefix) { protocol=[Group(line,prefix,1) lowercaseString];body=Group(line,prefix,2); }
    // Whitespace controls inside a credential/authority are never repaired.
    if ([body rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return nil;
    BOOL uri=[body rangeOfString:@"^[A-Za-z][A-Za-z0-9+.-]*://" options:NSRegularExpressionSearch].location!=NSNotFound;
    NSURLComponents *components=nil; NSString *title=@"";
    if (uri) {
        if (prefix) return nil; // Do not guess between contradictory protocol declarations.
        // Derive the scheme before parsing: malformed recognized URLs must not
        // fall into the original subscription downloader when parsing returns nil.
        protocol=[[body substringToIndex:[body rangeOfString:@"://"].location] lowercaseString];
        if ([protocol isEqual:@"ss"]) return @{@"protocol":@"legacy",@"value":body};
        if (![@[@"http",@"https",@"socks",@"socks5"] containsObject:protocol?:@""]) { *original=YES;return nil; }
        components=[NSURLComponents componentsWithString:body];
        if(!components)return nil;
        if(!components.host.length||!components.URL||
           [components.host rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound||
           (components.port&&(components.port.integerValue<1||components.port.integerValue>65535))||
           [body rangeOfString:@"%(?![0-9a-fA-F]{2})" options:NSRegularExpressionSearch].location!=NSNotFound)return nil;
        if ([protocol isEqual:@"http"]||[protocol isEqual:@"https"]) {
            // Paths/queries remain subscription input, never fetched by this module.
            if ((components.path.length&&![components.path isEqual:@"/"])||components.query||(!components.port&&!components.user)) { *original=YES;return nil; }
        }
        if (components.fragment) {
            title=components.fragment;
            if (title.length>256||[title rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return nil;
            components.fragment=nil;
        }
    } else {
        if (!protocol) protocol=@"socks5"; // Preserve the original schemeless interpretation.
        NSString *host=nil,*port=nil,*user=nil,*password=nil;
        NSTextCheckingResult *m=Match(body,@"(\\[[^\\]]+\\]|[^:@/\\s]+):([0-9]+)(?::([^:]+):(.*))?");
        if (m) { host=Group(body,m,1);port=Group(body,m,2);user=Group(body,m,3);password=Group(body,m,4); }
        else {
            NSRange at=[body rangeOfString:@"@" options:NSBackwardsSearch];
            if (at.location!=NSNotFound) {
                NSString *auth=[body substringToIndex:at.location],*authority=[body substringFromIndex:at.location+1];
                m=Match(authority,@"(\\[[^\\]]+\\]|[^:@/\\s]+):([0-9]+)");
                NSRange colon=[auth rangeOfString:@":"];
                if (m&&colon.location!=NSNotFound&&colon.location>0) { host=Group(authority,m,1);port=Group(authority,m,2);user=[auth substringToIndex:colon.location];password=[auth substringFromIndex:colon.location+1]; }
            }
        }
        if (!host) { if (!prefix&&![body containsString:@":"]) *original=YES; return nil; }
        NSString *auth=user?[NSString stringWithFormat:@"%@:%@@",Encode(user),Encode(password?:@"")]:@"";
        components=[NSURLComponents componentsWithString:[NSString stringWithFormat:@"http://%@%@:%@",auth,host,port]];
    }
    // Reuse SocialBox's established validator; no transport or DIRECT fallback.
    components.scheme=@"http";
    NSDictionary *parsed=RBXParseHTTPProxyURL(components.string);
    if (!parsed) return nil;
    NSMutableDictionary *result=[parsed mutableCopy];
    result[@"protocol"]=[protocol isEqual:@"socks"]?@"socks5":protocol;
    result[@"title"]=title;
    return [result copy];
}
LBXProxyInputPlan *LBXPlanProxyInput(id input) {
    LBXProxyInputPlan *plan=[[LBXProxyInputPlan alloc] initPrivate];
    if (![input isKindOfClass:NSString.class]||[input length]>262144||![input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]||[input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>262144) { plan.issue=@"Paste a proxy address or a list smaller than 256 KB.";return plan; }
    NSMutableArray *lines=[NSMutableArray array];
    for (NSString *line in [input componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if(!Trim(line).length)continue;
        // Leading layout before an explicit protocol cannot be a credential.
        // Never trim the end: a provider-format password may contain spaces.
        NSString *leading=[line stringByReplacingOccurrencesOfString:@"^\\s+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0,line.length)];
        BOOL explicit=[leading rangeOfString:@"^(?:(?:HTTP|HTTPS|SOCKS5|SOCKS)[ \\t]+|[A-Za-z][A-Za-z0-9+.-]*://)" options:(NSRegularExpressionSearch|NSCaseInsensitiveSearch)].location!=NSNotFound;
        [lines addObject:explicit?leading:line];
    }
    if (!lines.count||lines.count>500) { plan.issue=@"Paste between 1 and 500 proxy entries.";return plan; }
    NSMutableArray *endpoints=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for (NSUInteger i=0;i<lines.count;i++) {
        BOOL original=NO; NSDictionary *endpoint=nil;
        @try { if ([lines[i] length]<=4096) endpoint=Endpoint(lines[i],&original); } @catch (__unused NSException *error) { endpoint=nil; }
        if (original&&lines.count==1) { plan.useOriginalInput=YES;return plan; }
        if (!endpoint) { plan.issue=[NSString stringWithFormat:@"Line %lu: use a valid proxy address. Keep subscription links separate from proxy lists.",(unsigned long)i+1];return plan; }
        NSArray *key=[endpoint[@"protocol"] isEqual:@"legacy"]?@[endpoint[@"protocol"],endpoint[@"value"]]:@[endpoint[@"protocol"],endpoint[@"host"],endpoint[@"port"],endpoint[@"username"],endpoint[@"password"]];
        if ([seen containsObject:key]) {plan.duplicates++;continue;}
        [seen addObject:key];[endpoints addObject:endpoint];
    }
    plan.endpoints=[endpoints copy];return plan;
}
static IMP MethodFor(id receiver,NSString *name,const char *encoding) {
    Class cls=object_getClass(receiver);unsigned count=0;Method *list=class_copyMethodList(cls,&count);Method found=NULL;
    SEL sel=NSSelectorFromString(name);
    for(unsigned i=0;i<count;i++)if(method_getName(list[i])==sel) {found=list[i];break;}
    free(list);
    if (!found||strcmp(method_getTypeEncoding(found),encoding))return NULL;
    IMP imp=method_getImplementation(found);Dl_info image={0};
    if(!dladdr((void *)imp,&image)||!image.dli_fname)return NULL;
    NSString *actual=[@(image.dli_fname) stringByResolvingSymlinksInPath];
    NSString *expected=[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath];
    return [actual isEqual:expected]?imp:NULL;
}
BOOL LBXDispatchProxyInput(id receiver,LBXProxyInputPlan *plan,NSError **error) {
    BOOL valid=NSThread.isMainThread&&[NSStringFromClass(object_getClass(receiver)) isEqual:@"ProxyViewController"]&&object_getClass(plan)==LBXProxyInputPlan.class&&!plan.issue&&!plan.useOriginalInput&&plan.endpoints.count;
    NSMutableDictionary *methods=[NSMutableDictionary dictionary];
    NSDictionary *spec=@{@"http":@[@"addHTTPProxyWithHost:port:user:password:title:tls:",@"v60@0:8@16q24@32@40@48B56"],@"socks5":@[@"addSOCKS5ProxyWithHost:port:user:password:title:rotationUrl:",@"v64@0:8@16q24@32@40@48@56"],@"legacy":@[@"openProxyImportURL:",@"v24@0:8@16"]};
    if(valid)for(NSDictionary *e in plan.endpoints) {
        NSString *kind=[e[@"protocol"] isEqual:@"https"]?@"http":e[@"protocol"];
        NSArray *entry=spec[kind];IMP imp=entry?MethodFor(receiver,entry[0],[entry[1] UTF8String]):NULL;
        if(!imp){valid=NO;break;}methods[kind]=[NSValue valueWithPointer:imp];
    }
    if(!valid) { if(error)*error=[NSError errorWithDomain:@"com.socialbox.proxy-input" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Proxy import is unavailable for this input or app version. No new proxy was added by this importer."}];return NO; }
    // Retain reviewed IMPs: a later method replacement cannot redirect this batch.
    for(NSDictionary *e in plan.endpoints) {
        NSString *kind=[e[@"protocol"] isEqual:@"https"]?@"http":e[@"protocol"];
        IMP imp=[methods[kind] pointerValue];SEL sel=NSSelectorFromString(spec[kind][0]);
        if([kind isEqual:@"legacy"]) ((void(*)(id,SEL,id))imp)(receiver,sel,e[@"value"]);
        else if([kind isEqual:@"http"]) ((void(*)(id,SEL,id,NSInteger,id,id,id,BOOL))imp)(receiver,sel,e[@"host"],[e[@"port"] integerValue],e[@"username"],e[@"password"],e[@"title"],[e[@"protocol"] isEqual:@"https"]);
        else ((void(*)(id,SEL,id,NSInteger,id,id,id,id))imp)(receiver,sel,e[@"host"],[e[@"port"] integerValue],e[@"username"],e[@"password"],e[@"title"],nil);
    }
    return YES;
}
