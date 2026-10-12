#!/usr/bin/env python3
"""Execute the native read-only workspace projection; no daemon or user data."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
CODE = r'''
#import <Foundation/Foundation.h>
#import "RBXWorkspacePresentation.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d\n",__LINE__); return 1; } } while(0)
int main(void) { @autoreleasepool {
    NSDictionary *a=@{@"id":@"a",@"name":@"Alpha",@"lastActiveAt":@2,@"identity":@"iPhone 15"};
    NSDictionary *b=@{@"id":@"b",@"name":@"Beta",@"lastActiveAt":@5,@"isActive":@YES};
    NSDictionary *r=@{@"id":@"r",@"name":@"Recovery",@"profileError":@{@"message":@"Unreadable"}};
    NSArray *rows=@[a,b,r,@"bad",@{}];
    CHECK(RBXWorkspaceRows(rows,@"",0).count==3);
    CHECK([RBXWorkspaceRows(rows,@"",0).firstObject[@"id"] isEqual:@"b"]);
    CHECK([RBXWorkspaceRows(rows,@"",1).firstObject[@"id"] isEqual:@"a"]);
    CHECK(RBXWorkspaceRows(rows,@" iphone 15 ",0).count==2);
    CHECK(RBXWorkspaceRows(rows,@"missing",0).count==1); // recovery is never hidden
    CHECK([RBXWorkspaceSelectedRow(rows,@"a")[@"id"] isEqual:@"a"]);
    CHECK([RBXWorkspaceSelectedRow(rows,@"deleted")[@"id"] isEqual:@"b"]);
    CHECK(RBXWorkspaceSelectedRow(@[],@"a")==nil);
    CHECK([RBXWorkspaceDeviceText(@{}) isEqual:@"Identity not available"]);
    CHECK([RBXWorkspaceDeviceText(@{@"identityEditor":@{@"marketingName":@"iPhone 15",@"iosVersion":@"17.0"}}) isEqual:@"iPhone 15 · iOS 17.0"]);
    CHECK([RBXWorkspaceRows(@[a,@{@"id":@"c",@"lastActiveAt":@"bad"}],@"",0).firstObject[@"id"] isEqual:@"a"]);
    CHECK(RBXWorkspaceRows((id)@"bad",nil,0).count==0);
    puts("PASS workspace projection: search, stable sort, recovery visibility, explicit selection, deleted-selection fallback, malformed data");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix="rbx-workspace-") as directory:
    src=Path(directory)/"test.m"; src.write_text(CODE); binary=Path(directory)/"test"
    subprocess.run(["xcrun","clang","-fobjc-arc","-fblocks","-Wall","-Wextra","-Werror","-I"+str(ROOT/"launcher"),"-framework","Foundation",str(src),"-o",str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
