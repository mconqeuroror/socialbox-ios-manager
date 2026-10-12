#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
static unsigned Calls,FailCall,Checks,Authorizations,RevokeAt;
static int FaultChmod(int fd,mode_t mode){if(++Calls==FailCall){errno=EIO;return -1;}return fchmod(fd,mode);}
#define fchmod FaultChmod
#include "RBXStorageGate.h"
#undef fchmod
#define CHECK(x) do{Checks++;if(!(x)){fprintf(stderr,"FAIL line %d errno=%d\n",__LINE__,errno);exit(1);}}while(0)
static bool Authorize(void *unused){return ++Authorizations!=RevokeAt;}
static void Inspect(int fd,mode_t mode){struct stat s;CHECK(fstat(fd,&s)==0);CHECK((s.st_mode&07777)==mode);}
static RBXStorageGateEntry Entry(const char *root,unsigned index){
 char bundle[4096],home[4096],executable[4096];
 snprintf(bundle,sizeof(bundle),"%s/bundle-%u",root,index);snprintf(home,sizeof(home),"%s/home-%u",root,index);snprintf(executable,sizeof(executable),"%s/main",bundle);
 CHECK(mkdir(bundle,0700)==0&&mkdir(home,0700)==0);
 RBXStorageGateEntry e={.bundle=open(bundle,O_RDONLY|O_DIRECTORY),.home=open(home,O_RDONLY|O_DIRECTORY),.executable=open(executable,O_RDWR|O_CREAT|O_EXCL,0755)};
 CHECK(e.bundle>=0&&e.home>=0&&e.executable>=0);CHECK(write(e.executable,"synthetic-code",14)==14);
 struct stat s;CHECK(fstat(e.bundle,&s)==0);e.bundleDevice=s.st_dev;e.bundleInode=s.st_ino;
 CHECK(fstat(e.home,&s)==0);e.homeDevice=s.st_dev;e.homeInode=s.st_ino;
 CHECK(fstat(e.executable,&s)==0);e.executableDevice=s.st_dev;e.executableInode=s.st_ino;
 return e;
}
static bool Transition(RBXStorageGateEntry *e,size_t n,size_t selected){Authorizations=0;return RBXStorageGateTransition(e,n,selected,geteuid(),getegid(),geteuid(),getegid(),geteuid(),Authorize,NULL);}
int main(int argc,char **argv){
 CHECK(argc==2);RBXStorageGateEntry e[40];for(unsigned i=0;i<40;i++)e[i]=Entry(argv[1],i);
 for(unsigned round=0;round<3;round++)for(unsigned target=0;target<40;target++){
  CHECK(Transition(e,40,target));
  for(unsigned i=0;i<40;i++){Inspect(e[i].executable,i==target?0755:0600);Inspect(e[i].bundle,i==target?0755:0700);Inspect(e[i].home,0700);}
 }
 // Interrupted grants return all 40 to CLOSED, including a revocation just
 // after granting execution. Process reaping remains the caller's obligation.
 for(unsigned stage=1;stage<=4;stage++){
  RevokeAt=stage;CHECK(!Transition(e,40,5));
  for(unsigned i=0;i<40;i++){Inspect(e[i].executable,0600);Inspect(e[i].bundle,0700);Inspect(e[i].home,0700);}
 }
 RevokeAt=0;
 // Every permission syscall in an admission can fail. A seal failure must
 // prevent admission, while later executables still get a closure attempt.
 for(unsigned fault=1;fault<=246;fault++){
  CHECK(Transition(e,40,40));Calls=0;FailCall=fault;
  CHECK(!Transition(e,40,3));FailCall=0;
  for(unsigned i=0;i<40;i++)Inspect(e[i].executable,0600);
 }
 CHECK(Transition(e,40,40));RBXStorageGateEntry copy=e[4];e[4]=e[3];CHECK(!Transition(e,40,0));e[4]=copy;
 e[0].homeInode++;CHECK(!Transition(e,40,0));e[0].homeInode--;
 copy=e[0];e[0].home=e[0].bundle;e[0].homeDevice=e[0].bundleDevice;e[0].homeInode=e[0].bundleInode;CHECK(!Transition(e,40,0));e[0]=copy;
 copy=e[0];e[0].home=e[1].bundle;e[0].homeDevice=e[1].bundleDevice;e[0].homeInode=e[1].bundleInode;CHECK(!Transition(e,40,0));e[0]=copy;
 CHECK(linkat(e[0].bundle,"main",e[0].bundle,"hardlink",0)==0);CHECK(!Transition(e,40,0));CHECK(unlinkat(e[0].bundle,"hardlink",0)==0);
 CHECK(!RBXStorageGateTransition(e,40,0,geteuid(),getegid(),geteuid(),getegid(),geteuid(),NULL,NULL));
 for(unsigned i=0;i<40;i++){char bytes[14];CHECK(pread(e[i].executable,bytes,sizeof(bytes),0)==14);CHECK(!memcmp(bytes,"synthetic-code",14));close(e[i].executable);close(e[i].bundle);close(e[i].home);}
 printf("PASS %u storage gate assertions: 40 targets, 120 selections, revocation and syscall failures; host UID unchanged\n",Checks);
 return 0;
}
