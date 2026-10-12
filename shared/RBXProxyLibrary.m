#import "RBXProxyLibrary.h"
#import "RBXSecureConfig.h"
#import "RBXHTTPProxy.h"
static NSError *LibraryError(NSString *message) {
 return [NSError errorWithDomain:@"com.redditbox.proxy-library" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSArray *ConnectionKeys(void) { return @[@"proxyURL",@"rotationURL",@"authorization",@"authHeader",@"method"]; }
static NSDictionary *Connection(NSDictionary *entry) {
 NSMutableDictionary *result=[NSMutableDictionary dictionary];
 for(NSString *key in ConnectionKeys())result[key]=entry[key]?:@"";
 result[@"authHeader"]=[result[@"authHeader"] length]?result[@"authHeader"]:@"Authorization";
 result[@"method"]=[result[@"method"] length]?result[@"method"]:@"GET";
 return result;
}
static NSArray *Entries(NSDictionary *config, NSError **error) {
 id stored=config[@"proxyLibrary"];
 if(stored && (![stored isKindOfClass:NSArray.class] || [stored count]>100)) {
  if(error)*error=LibraryError(@"Saved proxy list is unreadable. It has been preserved.");return nil;
 }
 NSMutableArray *entries=[NSMutableArray array]; NSMutableSet *ids=[NSMutableSet set];
 for(id row in stored) {
  BOOL valid=[row isKindOfClass:NSDictionary.class];
  if(valid)for(NSString *key in [ConnectionKeys() arrayByAddingObjectsFromArray:@[@"id",@"name"]])if(![row[key] isKindOfClass:NSString.class])valid=NO;
  if(!valid || ![row[@"id"] length] || [ids containsObject:row[@"id"]]) {
   if(error)*error=LibraryError(@"Saved proxy list is corrupt. It has been preserved.");return nil;
  }
  [ids addObject:row[@"id"]]; NSMutableDictionary *entry=[row mutableCopy];
  if([row[@"id"] isEqual:config[@"selectedProxyId"]]) [entry addEntriesFromDictionary:Connection(config)];
  [entries addObject:entry];
 }
 if(!stored && [config[@"proxyURL"] length]) {
  NSMutableDictionary *legacy=[Connection(config) mutableCopy];legacy[@"id"]=@"current";legacy[@"name"]=@"My proxy";[entries addObject:legacy];
 }
 return entries;
}

// Exact parsed endpoint equality includes credentials: two sessions on one
// host/port may be different proxies and must not be collapsed together.
static NSDictionary *ImportPreview(NSString *text, NSArray *existing, NSError **error) {
 if(![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>262144) {
  if(error)*error=LibraryError(@"Paste a plain-text list up to 256 KB.");return nil;
 }
 NSString *normalizedLines=[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
 NSArray *lines=[normalizedLines componentsSeparatedByString:@"\n"];
 if(lines.count>501 || (lines.count==501 && [lines.lastObject length])) {
  if(error)*error=LibraryError(@"Import up to 500 lines at a time.");return nil;
 }
 NSMutableSet *seen=[NSMutableSet set];
 for(NSDictionary *row in existing) {
  NSDictionary *endpoint=RBXParseHTTPProxyURL([RBXProxyLibrary normalizedURL:row[@"proxyURL"]]);
  if(endpoint)[seen addObject:endpoint];
 }
 NSMutableArray *entries=[NSMutableArray array], *issues=[NSMutableArray array];
 NSUInteger duplicates=0, inputCount=0;
 for(NSUInteger index=0;index<lines.count;index++) {
  NSString *line=[lines[index] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if(!line.length)continue;
  inputCount++;
  NSString *url=[RBXProxyLibrary normalizedURL:line];
  NSDictionary *endpoint=RBXParseHTTPProxyURL(url);
  if(!endpoint) {
   NSString *lower=line.lowercaseString;
   NSString *reason=[lower hasPrefix:@"socks"] || [lower hasPrefix:@"https:"]
    ? @"Unsupported protocol. Use an HTTP proxy; SOCKS and HTTPS-to-proxy are not supported."
    : @"Invalid HTTP proxy. Use host:port, host:port:user:password or http://user:password@host:port.";
   [issues addObject:@{@"line":@(index+1),@"message":reason}];continue;
  }
  if([seen containsObject:endpoint]){duplicates++;continue;}
  [seen addObject:endpoint];
  NSString *host=endpoint[@"host"];
  NSString *name=[NSString stringWithFormat:@"%@:%@",[host containsString:@":"]?[@"[" stringByAppendingFormat:@"%@]",host]:host,endpoint[@"port"]];
  if(name.length>80)name=[name substringToIndex:80];
  [entries addObject:@{@"name":name,@"proxyURL":url,@"rotationURL":@"",@"authorization":@"",@"authHeader":@"Authorization",@"method":@"GET"}];
 }
 BOOL overflow=existing.count+entries.count>100;
 return @{@"formatVersion":@1,@"existingEntries":existing,@"entries":entries,@"issues":issues,
  @"inputCount":@(inputCount),@"newCount":@(entries.count),@"duplicateCount":@(duplicates),
  @"invalidCount":@(issues.count),@"existingCount":@(existing.count),@"capacityExceeded":@(overflow),
  @"canImport":@(entries.count>0 && !issues.count && !overflow)};
}
@implementation RBXProxyLibrary
+ (NSArray *)entries:(NSError **)error {
 NSError *e=nil;NSDictionary *config=[RBXSecureConfig rotationConfiguration:&e];
 if(e){if(error)*error=e;return nil;}return Entries(config?:@{},error);
}
+ (NSString *)selectedIdentifier:(NSError **)error {
 NSDictionary *config=[RBXSecureConfig rotationConfiguration:error];
 if([config[@"selectedProxyId"] isKindOfClass:NSString.class])return config[@"selectedProxyId"];
 return [config[@"proxyURL"] length]?@"current":@"";
}
+ (NSString *)normalizedURL:(NSString *)input {
 if (![input isKindOfClass:NSString.class] || input.length > 4096) return nil;
 NSString *text=[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 // A provider's copied "HTTP " label is not a URL scheme. Never downgrade
 // HTTPS/SOCKS or repair credentials by guessing or decoding them twice.
 if ([text rangeOfString:@"^HTTP[ \\t]+" options:NSRegularExpressionSearch|NSCaseInsensitiveSearch].location == 0)
  text=[text stringByReplacingOccurrencesOfString:@"^HTTP[ \\t]+" withString:@"" options:NSRegularExpressionSearch|NSCaseInsensitiveSearch range:NSMakeRange(0,text.length)];
 if (!text.length || [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
 if(![text containsString:@"://"]) {
  NSRegularExpression *provider=[NSRegularExpression regularExpressionWithPattern:@"^(\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9.-]+):([0-9]+):([^:]+):(.*)$" options:0 error:nil];
  NSTextCheckingResult *match=[provider firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];
  if(match) {
   NSURLComponents *u=[NSURLComponents new];u.scheme=@"http";
   u.host=[text substringWithRange:[match rangeAtIndex:1]];
   NSString *port=[text substringWithRange:[match rangeAtIndex:2]];
   if(port.length>5 || port.integerValue<1 || port.integerValue>65535)return nil;
   u.port=@(port.integerValue);u.user=[text substringWithRange:[match rangeAtIndex:3]];
   u.password=[text substringWithRange:[match rangeAtIndex:4]];text=u.string;
  } else text=[@"http://" stringByAppendingString:text?:@""];
 }
 NSDictionary *endpoint=RBXParseHTTPProxyURL(text);
 if (!endpoint) return nil;
 NSURLComponents *canonical=[NSURLComponents componentsWithString:text];
 canonical.scheme=@"http";
 NSString *host=endpoint[@"host"];
 canonical.host=[host containsString:@":"] ? [NSString stringWithFormat:@"[%@]",host] : host;
 canonical.path=@"";
 NSString *result=canonical.string;
 return [RBXParseHTTPProxyURL(result) isEqual:endpoint] ? result : nil;
}
+ (NSDictionary *)importPreviewForText:(NSString *)text error:(NSError **)error {
 @synchronized(self) {
  NSArray *rows=[self entries:error];if(!rows)return nil;
  return ImportPreview(text,rows,error);
 }
}
+ (BOOL)importText:(NSString *)text reviewedPreview:(NSDictionary *)preview error:(NSError **)error {
 @synchronized(self) { @synchronized(RBXSecureConfig.class) {
  NSArray *old=[self entries:error];if(!old)return NO;
  NSDictionary *current=ImportPreview(text,old,error);if(!current)return NO;
  if(![preview isKindOfClass:NSDictionary.class] || ![current isEqual:preview]) {
   if(error)*error=LibraryError(@"The list or saved proxies changed. Preview again before importing.");return NO;
  }
  if(![current[@"canImport"] boolValue]) {
   if(error)*error=LibraryError([current[@"capacityExceeded"] boolValue]?@"The list exceeds the 100 saved-proxy limit. Nothing was imported.":@"Fix invalid lines and include at least one new proxy. Nothing was imported.");return NO;
  }
  NSMutableArray *rows=[old mutableCopy];
  for(NSDictionary *candidate in current[@"entries"]) {
   NSMutableDictionary *row=[candidate mutableCopy];row[@"id"]=NSUUID.UUID.UUIDString;[rows addObject:row];
  }
  // One Keychain item update is the batch boundary. Preserve active proxy,
  // cloud authority, license, disabled state and rotation settings exactly.
  return [RBXSecureConfig saveRotationConfiguration:@{@"proxyLibrary":rows} error:error];
 } }
}
+ (BOOL)saveEntry:(NSDictionary *)entry error:(NSError **)error {
 @synchronized(self) {
  NSError *readError=nil;NSDictionary *config=[RBXSecureConfig rotationConfiguration:&readError];
  NSArray *old=readError?nil:Entries(config?:@{},&readError);if(readError){if(error)*error=readError;return NO;}
  NSMutableDictionary *value=[entry mutableCopy];
  for(NSString *key in ConnectionKeys())if(value[key] && ![value[key] isKindOfClass:NSString.class]) {if(error)*error=LibraryError(@"Proxy fields must be text.");return NO;}
  if(![value[@"id"] isKindOfClass:NSString.class] || ![value[@"id"] length] || [value[@"id"] length]>100 ||
     ![value[@"name"] isKindOfClass:NSString.class] || ![value[@"name"] length] || [value[@"name"] length]>80) {if(error)*error=LibraryError(@"Enter a name of up to 80 characters.");return NO;}
  NSString *url=[self normalizedURL:value[@"proxyURL"]];
  NSString *link=[value[@"rotationURL"]?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSURL *rotation=[NSURL URLWithString:link];
  if(!url || (link.length && (![rotation.scheme.lowercaseString isEqual:@"https"] || !rotation.host.length || rotation.user.length || rotation.password.length || rotation.fragment.length))) {if(error)*error=LibraryError(@"Enter an HTTP proxy with a port. The optional rotate link must use HTTPS.");return NO;}
  value[@"proxyURL"]=url;value[@"rotationURL"]=link;[value addEntriesFromDictionary:Connection(value)];
  NSCharacterSet *header=[NSCharacterSet characterSetWithCharactersInString:@"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"];
  if([value[@"authHeader"] length]>128 || [value[@"authHeader"] rangeOfCharacterFromSet:header.invertedSet].location!=NSNotFound ||
     [value[@"authorization"] length]>4096 || [value[@"authorization"] rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound || ![@[@"GET",@"POST"] containsObject:value[@"method"]]) {if(error)*error=LibraryError(@"Check the optional advanced rotation settings.");return NO;}
  NSMutableArray *rows=[old mutableCopy];NSUInteger index=[rows indexOfObjectPassingTest:^BOOL(NSDictionary *r,NSUInteger i,BOOL *stop){return [r[@"id"] isEqual:value[@"id"]];}];
  if(index==NSNotFound)[rows addObject:value];else rows[index]=value;
  if(rows.count>100){if(error)*error=LibraryError(@"At most 100 proxies can be saved.");return NO;}
  NSString *selected=config[@"selectedProxyId"]?:([config[@"proxyURL"] length]?@"current":@"");
  if(!old.count)selected=value[@"id"];
  NSMutableDictionary *update=[@{@"proxyLibrary":rows,@"selectedProxyId":selected} mutableCopy];
  if([selected isEqual:value[@"id"]]){[update addEntriesFromDictionary:Connection(value)];update[@"proxyDisabled"]=@NO;}
  update[@"source"]=@"launcher";
  return [RBXSecureConfig saveRotationConfiguration:update error:error];
 }
}
+ (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error {
 @synchronized(self) {
  NSArray *rows=[self entries:error];if(!rows)return NO;
  for(NSDictionary *row in rows)if([row[@"id"] isEqual:identifier]) {
   NSMutableDictionary *update=[Connection(row) mutableCopy];update[@"proxyLibrary"]=rows;update[@"selectedProxyId"]=identifier;update[@"proxyDisabled"]=@NO;
   update[@"source"]=@"launcher";
  return [RBXSecureConfig saveRotationConfiguration:update error:error];
  }
  if(error)*error=LibraryError(@"This proxy no longer exists.");return NO;
 }
}
+ (BOOL)deleteIdentifier:(NSString *)identifier error:(NSError **)error {
 @synchronized(self) {
  NSError *readError=nil;NSDictionary *config=[RBXSecureConfig rotationConfiguration:&readError];
  NSMutableArray *rows=readError?nil:[Entries(config?:@{},&readError) mutableCopy];
  if(readError){if(error)*error=readError;return NO;}
  NSIndexSet *indexes=[rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *r,NSUInteger i,BOOL *stop){return [r[@"id"] isEqual:identifier];}];
  if(!indexes.count){if(error)*error=LibraryError(@"This proxy no longer exists.");return NO;}[rows removeObjectsAtIndexes:indexes];
  NSString *selected=config[@"selectedProxyId"]?:([config[@"proxyURL"] length]?@"current":@"");
  NSMutableDictionary *update=[@{@"proxyLibrary":rows,@"selectedProxyId":selected} mutableCopy];
  if([selected isEqual:identifier]) {for(NSString *key in ConnectionKeys())update[key]=@"";update[@"selectedProxyId"]=@"";update[@"proxyDisabled"]=@YES;}
  update[@"source"]=@"launcher";
  return [RBXSecureConfig saveRotationConfiguration:update error:error];
 }
}
@end
