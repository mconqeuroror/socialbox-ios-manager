#!/usr/bin/env python3
"""Execute the shipped classifier against a sparse large file; require bounded I/O."""
import subprocess,tempfile,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]).read_text() if len(sys.argv)>1 else (root/'daemon/RBXCloneManager.m').read_text()
body=source[source.index('static BOOL RBXIsMachOAtPath'):source.index('// No archive-provided')]
fixture=r'''
#import <Foundation/Foundation.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
static int calls;
static ssize_t ProbeRead(int fd,void *p,size_t size,off_t offset) {
 if(size!=4 || offset!=0) abort(); calls++; return pread(fd,p,size,offset);
}
#define pread ProbeRead
BODY
#undef pread
int main(int argc,char **argv){@autoreleasepool{
 NSString *path=[NSString stringWithUTF8String:argv[1]];
 int fd=open(path.fileSystemRepresentation,O_RDWR|O_CREAT|O_EXCL,0600);if(fd<0)return 1;
 if(ftruncate(fd,1024LL*1024*1024))return 2;
 uint32_t magics[]={MH_MAGIC,MH_CIGAM,MH_MAGIC_64,MH_CIGAM_64,FAT_MAGIC,FAT_CIGAM,FAT_MAGIC_64,FAT_CIGAM_64};
 for(int i=0;i<8;i++){pwrite(fd,&magics[i],4,0);calls=0;if(!RBXIsMachOAtPath(path)||calls!=1)return 3;}
 uint32_t zero=0;pwrite(fd,&zero,4,0);if(RBXIsMachOAtPath(path))return 4;
 ftruncate(fd,2);if(RBXIsMachOAtPath(path))return 5;close(fd);
 NSString *link=[path stringByAppendingString:@".link"];symlink(path.fileSystemRepresentation,link.fileSystemRepresentation);
 if(RBXIsMachOAtPath(link)||RBXIsMachOAtPath(path.stringByDeletingLastPathComponent))return 6;
 puts("PASS: actual classifier uses four-byte reads for large Mach-O files; rejects resources, truncated files, links and directories");return 0;
}}
'''.replace('BODY',body)
with tempfile.TemporaryDirectory(prefix='rbx-macho-probe-') as tmp:
 d=Path(tmp);(d/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',str(d/'test.m'),'-o',str(d/'test')],check=True)
 subprocess.run([str(d/'test'),str(d/'large')],check=True)
