#!/usr/bin/env python3
"""Execute the shipped advanced role-filter block with adversarial recovery rows."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
launcher = (ROOT / 'launcher/RBXLauncherViewController.m').read_text()
start = launcher.index('static NSDictionary *RBXPendingReplacementForRow(')
pending = launcher[start:launcher.index('\n}\n', start) + 3]
start = launcher.index('    if (self.roleFilter.selectedSegmentIndex > 0) {')
body = launcher[start:launcher.index('    if (self.roleGrouping.on)', start)]
source = r'''
#import <Foundation/Foundation.h>
#import "RBXProfileMetadata.h"
__PENDING__
@interface FixtureRoleFilter : NSObject
@property NSInteger selectedSegmentIndex;
@end
@implementation FixtureRoleFilter
@end
@interface FixtureLauncher : NSObject
@property FixtureRoleFilter *roleFilter;
@property NSArray *containers;
- (void)apply;
@end
@implementation FixtureLauncher
- (void)apply { __BODY__ }
@end
static NSUInteger checks;
static void Check(BOOL value,NSString *message) {
    checks++;if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
int main(void) { @autoreleasepool {
    NSArray *rows=@[
        @{@"id":@"normal-signup",@"role":@"signup"},
        @{@"id":@"normal-default",@"role":@"default"},
        @{@"id":@"deleting",@"role":@"default",@"deletionState":@{@"message":@"pending"}},
        @{@"id":@"unreadable",@"role":@"default",@"profileError":@{@"message":@"pending"}},
        @{@"id":@"replacement",@"role":@"default",@"replacementState":@{@"phase":@"prepared"}},
        @{@"id":@"alert",@"role":@"default",@"isolationSentinel":@{@"alert":@YES}},
        @{@"id":@"committed",@"role":@"default",@"replacementState":@{@"phase":@"committed"}},
        @{@"id":@"clear",@"role":@"default",@"isolationSentinel":@{@"alert":@NO}},
        @{@"id":@"malformed",@"role":@"default",@"isolationSentinel":@"bad",@"replacementState":@"bad"},
        @{@"id":@"empty",@"role":@"default",@"replacementState":@{}}
    ];
    NSArray *original=[rows copy];
    FixtureLauncher *view=[FixtureLauncher new];view.roleFilter=[FixtureRoleFilter new];
    for(NSInteger role=1;role<=4;role++) {
        view.containers=rows;view.roleFilter.selectedSegmentIndex=role;[view apply];
        NSArray *ids=[view.containers valueForKey:@"id"];
        for(NSString *identifier in @[@"deleting",@"unreadable",@"replacement",@"alert"])
            Check([ids containsObject:identifier],@"Every role keeps deletion, profile, replacement and isolation recovery visible");
        if(role==1) {
            Check([ids isEqual:@[@"normal-signup",@"deleting",@"unreadable",@"replacement",@"alert"]],@"Role membership and existing row order remain exact");
            for(NSString *identifier in @[@"committed",@"clear",@"malformed",@"empty"])
                Check(![ids containsObject:identifier],@"Completed, empty and malformed states are not false alerts");
        }
    }
    view.containers=rows;view.roleFilter.selectedSegmentIndex=0;[view apply];
    Check([view.containers isEqual:rows],@"All roles retains complete inventory");
    Check([original isEqual:rows],@"Filtering does not mutate profiles or identity fields");
    printf("PASS: %lu actual advanced role-filter assertions\n",(unsigned long)checks);
    return 0;
}}
'''.replace('__PENDING__', pending).replace('__BODY__', body)
with tempfile.TemporaryDirectory(prefix='rbx-role-filter-') as directory:
    path=Path(directory);(path/'test.m').write_text(source)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-unused-function',
                    '-I'+str(ROOT/'shared'),'-framework','Foundation',str(path/'test.m'),
                    '-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
