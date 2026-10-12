#pragma once
#import <Foundation/Foundation.h>

@interface SBProxyRecord : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *protocol;
@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *port;
@property(nonatomic, copy) NSString *user;
@property(nonatomic, copy) NSString *password;
- (NSString *)displayHost;
- (NSString *)connectionLine;
@end

@interface SBProxyStore : NSObject
- (NSArray<SBProxyRecord *> *)entries:(NSError **)error;
- (NSString *)selectedIdentifier:(NSError **)error;
- (BOOL)saveRecord:(SBProxyRecord *)record error:(NSError **)error;
- (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)deleteIdentifier:(NSString *)identifier error:(NSError **)error;
- (SBProxyRecord *)parseLine:(NSString *)line;
- (NSArray<SBProxyRecord *> *)recordsFromPastedText:(NSString *)text issues:(NSArray<NSString *> **)issues;
@end
