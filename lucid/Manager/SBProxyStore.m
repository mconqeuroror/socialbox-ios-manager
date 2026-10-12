#import "SBProxyStore.h"

static NSString *const SBProxyStorePath = @"/private/var/mobile/Library/SocialBox/ProxyLibrary.plist";

@implementation SBProxyRecord
- (NSString *)displayHost {
    NSString *host = self.host.length ? self.host : @"—";
    return [NSString stringWithFormat:@"%@:%@", host, self.port.length ? self.port : @"—"];
}
- (NSString *)connectionLine {
    NSString *scheme = self.protocol.length ? self.protocol : @"socks5";
    if (self.user.length) {
        return [NSString stringWithFormat:@"%@://%@:%@@%@:%@", scheme, self.user, self.password ?: @"",
                self.host, self.port];
    }
    return [NSString stringWithFormat:@"%@://%@:%@", scheme, self.host, self.port];
}
- (NSDictionary *)dictionary {
    return @{
        @"id" : self.identifier ?: @"",
        @"name" : self.name ?: @"",
        @"protocol" : self.protocol ?: @"socks5",
        @"host" : self.host ?: @"",
        @"port" : self.port ?: @"",
        @"user" : self.user ?: @"",
        @"password" : self.password ?: @"",
    };
}
+ (instancetype)fromDictionary:(NSDictionary *)row {
    if (![row isKindOfClass:NSDictionary.class]) return nil;
    SBProxyRecord *record = [SBProxyRecord new];
    record.identifier = [row[@"id"] isKindOfClass:NSString.class] ? row[@"id"] : @"";
    record.name = [row[@"name"] isKindOfClass:NSString.class] ? row[@"name"] : @"";
    record.protocol = [row[@"protocol"] isKindOfClass:NSString.class] ? row[@"protocol"] : @"socks5";
    record.host = [row[@"host"] isKindOfClass:NSString.class] ? row[@"host"] : @"";
    record.port = [row[@"port"] isKindOfClass:NSString.class] ? row[@"port"] : @"";
    record.user = [row[@"user"] isKindOfClass:NSString.class] ? row[@"user"] : @"";
    record.password = [row[@"password"] isKindOfClass:NSString.class] ? row[@"password"] : @"";
    if (!record.identifier.length || !record.host.length || !record.port.length) return nil;
    return record;
}
@end

@implementation SBProxyStore

static NSString *SBTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSMutableDictionary *)loadRoot:(NSError **)error {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:SBProxyStorePath];
    if (!root) return [@{@"entries" : @[], @"selectedId" : @""} mutableCopy];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"entries"] isKindOfClass:NSArray.class]) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.proxy" code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"Saved proxy list is unreadable."}];
        return nil;
    }
    return [root mutableCopy];
}

- (BOOL)writeRoot:(NSDictionary *)root error:(NSError **)error {
    [[NSFileManager defaultManager] createDirectoryAtPath:SBProxyStorePath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    if (![root writeToFile:SBProxyStorePath atomically:YES]) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.proxy" code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"Could not save proxies."}];
        return NO;
    }
    return YES;
}

- (NSArray<SBProxyRecord *> *)entries:(NSError **)error {
    NSDictionary *root = [self loadRoot:error];
    if (!root) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id row in root[@"entries"]) {
        SBProxyRecord *record = [SBProxyRecord fromDictionary:row];
        if (record) [out addObject:record];
    }
    return out;
}

- (NSString *)selectedIdentifier:(NSError **)error {
    NSDictionary *root = [self loadRoot:error];
    id value = root[@"selectedId"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (BOOL)saveRecord:(SBProxyRecord *)record error:(NSError **)error {
    if (!record.host.length || record.port.integerValue < 1 || record.port.integerValue > 65535) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.proxy" code:3
                                     userInfo:@{NSLocalizedDescriptionKey : @"Enter host and a port from 1 to 65535."}];
        return NO;
    }
    if (!record.identifier.length) record.identifier = NSUUID.UUID.UUIDString;
    if (!record.name.length) record.name = record.displayHost;
    if (record.name.length > 80) record.name = [record.name substringToIndex:80];
    if (!record.protocol.length) record.protocol = @"socks5";
    NSMutableDictionary *root = [self loadRoot:error];
    if (!root) return NO;
    NSMutableArray *rows = [root[@"entries"] mutableCopy] ?: [NSMutableArray array];
    NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(id row, NSUInteger i, BOOL *stop) {
        (void)i;
        (void)stop;
        return [row[@"id"] isEqual:record.identifier];
    }];
    if (index == NSNotFound) {
        if (rows.count >= 100) {
            if (error)
                *error = [NSError errorWithDomain:@"com.socialbox.proxy" code:4
                                         userInfo:@{NSLocalizedDescriptionKey : @"At most 100 proxies can be saved."}];
            return NO;
        }
        [rows addObject:record.dictionary];
    } else {
        rows[index] = record.dictionary;
    }
    root[@"entries"] = rows;
    if (![root[@"selectedId"] length]) root[@"selectedId"] = record.identifier;
    return [self writeRoot:root error:error];
}

- (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error {
    NSMutableDictionary *root = [self loadRoot:error];
    if (!root) return NO;
    BOOL found = NO;
    for (id row in root[@"entries"]) {
        if ([row[@"id"] isEqual:identifier]) found = YES;
    }
    if (!found) {
        if (error)
            *error = [NSError errorWithDomain:@"com.socialbox.proxy" code:5
                                     userInfo:@{NSLocalizedDescriptionKey : @"This proxy no longer exists."}];
        return NO;
    }
    root[@"selectedId"] = identifier;
    return [self writeRoot:root error:error];
}

- (BOOL)deleteIdentifier:(NSString *)identifier error:(NSError **)error {
    NSMutableDictionary *root = [self loadRoot:error];
    if (!root) return NO;
    NSMutableArray *rows = [root[@"entries"] mutableCopy] ?: [NSMutableArray array];
    [rows filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id row, NSDictionary *b) {
        (void)b;
        return ![row[@"id"] isEqual:identifier];
    }]];
    root[@"entries"] = rows;
    if ([root[@"selectedId"] isEqual:identifier]) root[@"selectedId"] = @"";
    return [self writeRoot:root error:error];
}

- (SBProxyRecord *)parseLine:(NSString *)line {
    NSString *text = SBTrim(line);
    if (!text.length || text.length > 4096) return nil;
    if ([text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSString *protocol = nil;
    NSRegularExpression *prefix = [NSRegularExpression
        regularExpressionWithPattern:@"^(HTTP|HTTPS|SOCKS5|SOCKS)[ \\t]+(.+)$"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSTextCheckingResult *pre = [prefix firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (pre) {
        protocol = [[text substringWithRange:[pre rangeAtIndex:1]] lowercaseString];
        text = [text substringWithRange:[pre rangeAtIndex:2]];
    }
    if ([text containsString:@"://"]) {
        NSURLComponents *url = [NSURLComponents componentsWithString:text];
        if (!url.host.length || !url.port) return nil;
        NSInteger port = url.port.integerValue;
        if (port < 1 || port > 65535) return nil;
        SBProxyRecord *record = [SBProxyRecord new];
        record.protocol = protocol ?: (url.scheme.length ? url.scheme.lowercaseString : @"socks5");
        if ([record.protocol isEqual:@"socks"]) record.protocol = @"socks5";
        if ([record.protocol isEqual:@"https"]) record.protocol = @"http";
        record.host = url.host;
        record.port = port ? [NSString stringWithFormat:@"%ld", (long)port] : @"80";
        record.user = url.user ?: @"";
        record.password = url.password ?: @"";
        record.name = record.displayHost;
        return record;
    }
    NSRegularExpression *full = [NSRegularExpression
        regularExpressionWithPattern:@"^(\\[[^\\]]+\\]|[^:@/\\s]+):([0-9]+)(?::([^:]+):(.*))?$"
                             options:0
                               error:nil];
    NSTextCheckingResult *m = [full firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m) return nil;
    NSInteger port = [[text substringWithRange:[m rangeAtIndex:2]] integerValue];
    if (port < 1 || port > 65535) return nil;
    SBProxyRecord *record = [SBProxyRecord new];
    record.protocol = protocol.length ? protocol : @"socks5";
    if ([record.protocol isEqual:@"socks"]) record.protocol = @"socks5";
    record.host = [text substringWithRange:[m rangeAtIndex:1]];
    record.port = [NSString stringWithFormat:@"%ld", (long)port];
    if ([m rangeAtIndex:3].location != NSNotFound) {
        record.user = [text substringWithRange:[m rangeAtIndex:3]];
        record.password = [text substringWithRange:[m rangeAtIndex:4]];
    }
    record.name = record.displayHost;
    return record;
}

- (NSArray<SBProxyRecord *> *)recordsFromPastedText:(NSString *)text issues:(NSArray<NSString *> **)issues {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *bad = [NSMutableArray array];
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r"
                                  withString:@"\n"];
    NSArray *lines = [normalized componentsSeparatedByString:@"\n"];
    NSUInteger n = 0;
    for (NSString *line in lines) {
        n++;
        if (!SBTrim(line).length) continue;
        SBProxyRecord *record = [self parseLine:line];
        if (!record) {
            [bad addObject:[NSString stringWithFormat:@"Line %lu is not a proxy.", (unsigned long)n]];
            continue;
        }
        [out addObject:record];
    }
    if (issues) *issues = bad;
    return out;
}

@end
