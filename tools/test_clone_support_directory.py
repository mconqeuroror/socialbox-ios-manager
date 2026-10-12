#!/usr/bin/env python3
"""Actual clone support directory traversal with real files and injected syscall failure."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'daemon/RBXCloneManager.m').read_text()
method=source[source.index('- (BOOL)_operation_syncProfile:'):]
assert 'RBXCloneSupportDirectory(container,501,501,error)' in method, 'all profile parents must use checked owner traversal'
harness=r'''#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
static BOOL FailChmod;
static int Chmod(int fd,mode_t mode){if(FailChmod){errno=EPERM;return -1;}return fchmod(fd,mode);}
#define fchmod Chmod
#import "RBXCloneSupportDirectory.h"
#undef fchmod
static NSUInteger checks;
static void Check(BOOL ok,NSString *s){checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",s.UTF8String);exit(1);}}
int main(int argc,char **argv){@autoreleasepool{
 NSString *root=@(argv[1]);NSFileManager *fm=NSFileManager.defaultManager;NSError *e=nil;
 for(NSString *caseName in @[@"fresh",@"existing",@"symlink",@"regular",@"chmod-failure",@"foreign-owner"]){
  NSString *home=[root stringByAppendingPathComponent:caseName];[fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *library=[home stringByAppendingPathComponent:@"Library"],*support=[library stringByAppendingPathComponent:@"Application Support"];
  if(![caseName isEqual:@"fresh"])[fm createDirectoryAtPath:library withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0755} error:nil];
  if([caseName isEqual:@"symlink"])symlink(root.fileSystemRepresentation,support.fileSystemRepresentation);
  if([caseName isEqual:@"regular"])[@"sentinel" writeToFile:support atomically:YES encoding:NSUTF8StringEncoding error:nil];
  if([caseName isEqual:@"existing"])[fm createDirectoryAtPath:support withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0750} error:nil];
  FailChmod=[caseName isEqual:@"chmod-failure"];uid_t owner=[caseName isEqual:@"foreign-owner"]?getuid()+1:getuid();
  NSString *result=RBXCloneSupportDirectory(home,owner,getgid(),&e);
  BOOL expected=[@[@"fresh",@"existing"] containsObject:caseName];Check((result!=nil)==expected,caseName);
  if(expected){
   for(NSString *part in @[library,support,result]){struct stat st;Check(lstat(part.fileSystemRepresentation,&st)==0&&S_ISDIR(st.st_mode)&&st.st_uid==getuid(),@"each parent owned and real");}
   struct stat st;lstat(result.fileSystemRepresentation,&st);Check((st.st_mode&0777)==0700,@"private control directory");
   Check([RBXCloneSupportDirectory(home,owner,getgid(),nil) isEqual:result],@"idempotent traversal");
   if([caseName isEqual:@"existing"]){lstat(support.fileSystemRepresentation,&st);Check((st.st_mode&0777)==0750,@"existing app-owned parent permissions retained");}
  }else Check(e!=nil,@"failure is explicit");
 }
 Check(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"RedditBox"]],@"symlink target never modified");
 printf("PASS %lu actual clone support directory assertions\n",(unsigned long)checks);
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='rbx-support-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(harness)
 subprocess.run(['xcrun','clang','-fobjc-arc','-Wall','-Wextra','-I'+str(ROOT/'shared'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'homes')],check=True)
