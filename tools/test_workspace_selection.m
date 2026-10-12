#import <Foundation/Foundation.h>
#import "RBXWorkspaceSelection.h"
static NSUInteger Checks;
static void Check(BOOL ok, NSString *message) { Checks++; if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
int main(void) { @autoreleasepool {
    __block NSDictionary *saved = nil;
    NSMutableArray *events = [NSMutableArray array];
    for (NSUInteger i=0; i<40; i++) {
        NSString *identifier = [NSString stringWithFormat:@"fixture-%lu",(unsigned long)i];
        NSString *token = NSUUID.UUID.UUIDString;
        BOOL ok = RBXSelectWorkspace(@"facebook", identifier, token,
            ^BOOL(NSDictionary *record) { [events addObject:record[@"phase"]]; saved=record; return YES; },
            ^BOOL { [events addObject:@"close-stop-drain"]; Check(!RBXWorkspaceSelectedID(saved,@"facebook"),@"pending cannot launch"); return YES; },
            ^BOOL { [events addObject:@"revalidate"]; return YES; });
        Check(ok && [RBXWorkspaceSelectedID(saved,@"facebook") isEqual:identifier],@"all forty resolve their exact selection");
        Check(!RBXWorkspaceSelectedID(saved,@"reddit"),@"foreign app cannot resolve selection");
        Check([events isEqual:@[@"switching",@"close-stop-drain",@"revalidate",@"selected"]],@"commit strictly follows closure and revalidation");
        NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:saved format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        saved=[NSPropertyListSerialization propertyListWithData:bytes options:0 format:nil error:nil];
        Check([RBXWorkspaceSelectedID(saved,@"facebook") isEqual:identifier],@"selection survives restart serialization");
        [events removeAllObjects];
    }
    for (NSUInteger failure=0;failure<4;failure++) {
        saved=nil; __block NSUInteger writes=0,closes=0,validates=0;
        BOOL ok=RBXSelectWorkspace(@"facebook",@"next",NSUUID.UUID.UUIDString,
            ^BOOL(NSDictionary *record){ writes++; if ((failure==0&&writes==1)||(failure==3&&writes==2)) return NO; saved=record; return YES; },
            ^BOOL{ closes++; return failure!=1; }, ^BOOL{ validates++; return failure!=2; });
        Check(!ok && !RBXWorkspaceSelectedID(saved,@"facebook"),@"any failed stage prevents selected launch");
        if(failure==0)Check(closes==0&&validates==0,@"publication failure performs no later stage");
        if(failure==1)Check(validates==0,@"closure failure never advances");
    }
    Check(!RBXSelectWorkspace(@"other",@"ok",NSUUID.UUID.UUIDString,^BOOL(id r){(void)r;abort();},^BOOL{abort();},^BOOL{abort();}),@"unknown app rejected before effects");
    Check(!RBXSelectWorkspace(@"facebook",@"../bad",NSUUID.UUID.UUIDString,^BOOL(id r){(void)r;abort();},^BOOL{abort();},^BOOL{abort();}),@"unsafe identifier rejected");
    Check(!RBXWorkspaceSelectedID(@{@"phase":@"selected",@"appType":@"facebook",@"containerId":@"x"},@"facebook"),@"partial record rejected");
    Check(!RBXWorkspaceSelectedID((id)@[],@"facebook"),@"malformed record rejected");
    puts([[NSString stringWithFormat:@"Workspace selection: %lu assertions PASS (40 profiles, ordering, restart and faults).",(unsigned long)Checks] UTF8String]);
} return 0; }
