#pragma once
#import <Foundation/Foundation.h>
#import <arpa/inet.h>

static inline NSData *RBXProxyNumericAddress(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return nil;
    struct in_addr v4; struct in6_addr v6;
    if (inet_pton(AF_INET,text.UTF8String,&v4)==1) return [NSData dataWithBytes:&v4 length:sizeof(v4)];
    if (inet_pton(AF_INET6,text.UTF8String,&v6)==1) return [NSData dataWithBytes:&v6 length:sizeof(v6)];
    return nil;
}

// NSURLSession evidence for the daemon's single-proxy health request only.
// Missing metrics/cache-only results never turn a configured PAC into proof.
static inline NSString *RBXProxyRouteVerdict(NSArray *transactions, NSArray *addresses, NSInteger port) {
    if (![transactions isKindOfClass:NSArray.class] || !transactions.count || transactions.count > 64 ||
        !addresses.count || addresses.count>32 || port<1 || port>65535) return @"NOT_RUN";
    NSMutableSet *allowed=[NSMutableSet set];
    for (NSString *address in addresses) { NSData *numeric=RBXProxyNumericAddress(address); if(!numeric) return @"NOT_RUN"; [allowed addObject:numeric]; }
    BOOL complete = YES;
    for (NSURLSessionTaskTransactionMetrics *transaction in transactions) {
        if (transaction.resourceFetchType != NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad) { complete = NO; continue; }
        // CFNetwork can report isProxyConnection=NO for a working PAC proxy.
        // Bind the actual socket peer to the selected proxy's resolved address
        // and explicit port instead of trusting that ambiguous flag.
        NSData *peer=RBXProxyNumericAddress(transaction.remoteAddress);
        if (!peer || !transaction.remotePort) { complete=NO; continue; }
        if (![allowed containsObject:peer] || transaction.remotePort.integerValue!=port) return @"LEAK";
        if (!transaction.response) complete = NO;
    }
    return complete ? @"PASS" : @"NOT_RUN";
}

@interface RBXProxyRouteObserver : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, copy) NSString *verdict;
@property(nonatomic, copy) NSArray *addresses;
@property(nonatomic) NSInteger port;
@end
