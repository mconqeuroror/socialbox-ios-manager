#import <Foundation/Foundation.h>

@interface RBXMDMExporter : NSObject
+ (NSArray<NSURL *> *)exportFilesForContainers:(NSArray<NSDictionary *> *)containers
                                         error:(NSError **)error;
+ (NSArray<NSURL *> *)exportFilesForContainers:(NSArray<NSDictionary *> *)containers
                                     appType:(NSString *)appType error:(NSError **)error;
@end
