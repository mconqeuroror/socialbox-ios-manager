#pragma once
#import <Foundation/Foundation.h>

// v1 transport: HTTP forward proxy / CONNECT, optionally Basic or Digest auth.
// An https:// upstream requires TLS-to-proxy support; it is not an alias for HTTP.
FOUNDATION_EXPORT NSDictionary *RBXParseHTTPProxyURL(NSString *text);
FOUNDATION_EXPORT NSDictionary *RBXHTTPProxySettings(NSDictionary *endpoint);

@interface RBXHTTPProxyDelegate : NSObject <NSURLSessionTaskDelegate>
- (instancetype)initWithDelegate:(id)delegate
    endpoint:(NSDictionary *(^)(void))endpoint;
// Optional destination policy for redirects. Rechecked after the application
// delegate answers, including when it substitutes a request asynchronously.
- (instancetype)initWithDelegate:(id)delegate
    endpoint:(NSDictionary *(^)(void))endpoint
    requestAllowed:(BOOL (^)(NSURLRequest *))requestAllowed;
@end
