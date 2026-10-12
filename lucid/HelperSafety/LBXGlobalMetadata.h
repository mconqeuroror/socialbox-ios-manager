#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// A single-file transaction, not a container data/network transaction. NO
// after rename may mean publication occurred but durability was not confirmed.
BOOL LBXWriteGlobalMetadata(NSString *path,NSDictionary *metadata);
BOOL LBXMutateGlobalMetadata(NSString *path,void (^mutation)(NSMutableDictionary *metadata));
BOOL LBXInstallGlobalMetadata(Class owner,uintptr_t getter,uintptr_t writer,uintptr_t mutator);
