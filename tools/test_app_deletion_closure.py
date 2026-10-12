#!/usr/bin/env python3
"""Actual deletion closure sequence; fake gate/coordinator, real lease/binding files."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()
start = source.index('- (BOOL)_deletionIsClosed:')
method = source[start:source.index('\n}\n', start) + 3]
header = (ROOT / "daemon/RBXAppProcessCoordinator.h").read_text()
begin = header.index("static inline NSTimeInterval RBXGlobalProcessStopBudget(void)")
budget = header[begin:header.index("\n}\n", begin) + 3]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
__BUDGET__
static NSString *kActiveBindingPath,*LeasePath;
static BOOL CloseOK,StopOK,WaitOK,ReopenDuringStop;
static NSUInteger Stops,Closes,Waits,Checks;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static NSError *RBXDeletionError(NSString *message){return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
static BOOL RBXRegistryCheckOperation(BOOL mutation,NSError **error){return YES;}
static void Lease(NSString *state,NSString *generation){Check([@{@"state":state,@"generation":generation} writeToFile:LeasePath atomically:YES],@"fixture lease written");}
@interface RBXNetworkGate : NSObject
+ (NSString *)leasePath;
+ (BOOL)closeTrafficWithReason:(NSString *)reason error:(NSError **)error;
+ (BOOL)waitForMaintenanceClosure:(NSString *)generation timeout:(NSTimeInterval)timeout;
@end
@implementation RBXNetworkGate
+ (NSString *)leasePath{return LeasePath;}
+ (BOOL)closeTrafficWithReason:(NSString *)reason error:(NSError **)error{Closes++;if(CloseOK){Lease(@"closed",@"new-generation");[@"none" writeToFile:kActiveBindingPath atomically:YES encoding:NSUTF8StringEncoding error:nil];}return CloseOK;}
+ (BOOL)waitForMaintenanceClosure:(NSString *)generation timeout:(NSTimeInterval)timeout{Waits++;NSDictionary *lease=[NSDictionary dictionaryWithContentsOfFile:LeasePath];return WaitOK && [lease[@"state"] isEqual:@"closed"] && [lease[@"generation"] isEqual:generation];}
@end
@interface RBXAppProcessCoordinator : NSObject
- (BOOL)killAllAndWait:(NSTimeInterval)timeout;
@end
@implementation RBXAppProcessCoordinator
- (BOOL)killAllAndWait:(NSTimeInterval)timeout{
    Stops++;Check([[[NSDictionary dictionaryWithContentsOfFile:LeasePath] objectForKey:@"state"] isEqual:@"closed"],@"global coordinator receives stop only after closed lease");
    Check(timeout>=8.0&&timeout<=30.0,@"bounded all-registered-family maintenance stop budget");
    if(ReopenDuringStop)Lease(@"open",@"changed-generation");return StopOK;
}
@end
@interface Closure : NSObject
@end
@implementation Closure
__METHOD__
@end
static void Reset(void){Closes=Stops=Waits=0;CloseOK=StopOK=WaitOK=YES;ReopenDuringStop=NO;Lease(@"closed",@"initial-generation");[@"none" writeToFile:kActiveBindingPath atomically:YES encoding:NSUTF8StringEncoding error:nil];}
int main(int argc,char **argv){@autoreleasepool{
    NSString *root=@(argv[1]);Check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil],@"private roots created");
    kActiveBindingPath=[root stringByAppendingPathComponent:@"binding"];LeasePath=[root stringByAppendingPathComponent:@"lease.plist"];
    Closure *closure=[Closure new];
    Reset();Lease(@"open",@"old-generation");[@"alpha" writeToFile:kActiveBindingPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check([closure _deletionIsClosed:@"alpha" establish:YES error:nil] && Closes==1 && Stops==1 && Waits==1,@"establish closes before all-app stop and verifies resulting generation");
    Reset();Check([closure _deletionIsClosed:@"alpha" establish:NO error:nil] && !Closes && Stops==1 && Waits==1,@"subsequent phases reverify global closure without opening or arming");
    Reset();CloseOK=NO;Check(![closure _deletionIsClosed:@"alpha" establish:YES error:nil] && !Stops && !Waits,@"failed close prevents process and phase advancement");
    Reset();StopOK=NO;Check(![closure _deletionIsClosed:@"alpha" establish:YES error:nil] && Stops==1 && !Waits,@"any failed coordinated stop denies deletion phase");
    Reset();WaitOK=NO;Check(![closure _deletionIsClosed:@"alpha" establish:YES error:nil],@"missing maintenance closure proof denies phase");
    Reset();ReopenDuringStop=YES;Check(![closure _deletionIsClosed:@"alpha" establish:YES error:nil] && Waits==1,@"changed lease during stop cannot reuse earlier closed proof");
    Reset();Lease(@"open",@"other-generation");Check(![closure _deletionIsClosed:@"alpha" establish:NO error:nil] && !Stops,@"open lease denies retry before process work");
    Reset();Lease(@"closed",@"");Check(![closure _deletionIsClosed:@"alpha" establish:NO error:nil] && !Stops,@"missing generation is not closure proof");
    Reset();[@"alpha" writeToFile:kActiveBindingPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check(![closure _deletionIsClosed:@"alpha" establish:NO error:nil] && !Stops,@"reappeared active target binding denies retry");
    Check([NSFileManager.defaultManager removeItemAtPath:root error:nil],@"temporary lease files removed");
    printf("PASS: %lu actual deletion closure/coordinator boundary assertions\n",(unsigned long)Checks);return 0;
}}
'''.replace('__METHOD__', method).replace('__BUDGET__', budget)
with tempfile.TemporaryDirectory(prefix='socialbox-deletion-closure-') as directory:
    build = Path(directory)
    (build / 'test.m').write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types',
                    '-I'+str(ROOT/'shared'), '-framework', 'Foundation', str(build / 'test.m'), '-o', str(build / 'test')], check=True)
    subprocess.run([str(build / 'test'), str(build / 'data')], check=True)
