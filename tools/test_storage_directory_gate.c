#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdbool.h>
static unsigned Calls,FailCall,Checks,Authorizations,RevokeAt;
static unsigned Effects,FailEffect,PersistentFault;
static unsigned FlagCalls,IgnoreFlagCall,StatCalls,FailStatCall;
static unsigned AtStatCalls,FailAtStatCall;
static bool RoleMode;
typedef struct {dev_t device;ino_t inode;uid_t owner;gid_t group;mode_t mode;unsigned int flags;} Role;
static Role Roles[40];
static size_t RoleCount;
static uid_t RootRole,AppRole;
static gid_t RootGroup,AppGroup;
static int RoleIndex(int fd){struct stat s;if(fstat(fd,&s))return -1;for(size_t i=0;i<RoleCount;i++)if(Roles[i].device==s.st_dev&&Roles[i].inode==s.st_ino)return (int)i;return -1;}
static bool FaultEffect(void){if(!RoleMode)return false;Effects++;if(Effects==FailEffect||(PersistentFault&&Effects>=PersistentFault)){errno=EIO;return true;}return false;}
static int FaultChmod(int fd,mode_t mode){if(++Calls==FailCall||FaultEffect()){errno=EIO;return -1;}if(!RoleMode)return fchmod(fd,mode);int index=RoleIndex(fd);if(index<0){errno=EINVAL;return -1;}if(Roles[index].flags&UF_IMMUTABLE){errno=EPERM;return -1;}if(fchmod(fd,mode?:0700))return -1;Roles[index].mode=mode;return 0;}
static int FaultChown(int fd,uid_t owner,gid_t group){if(FaultEffect())return -1;if(!RoleMode)return fchown(fd,owner,group);int index=RoleIndex(fd);if(index<0){errno=EINVAL;return -1;}if(Roles[index].flags&UF_IMMUTABLE){errno=EPERM;return -1;}if(fchown(fd,geteuid(),getegid()))return -1;Roles[index].owner=owner;Roles[index].group=group;return 0;}
static int FaultFlags(int fd,unsigned int flags){if(FaultEffect())return -1;if(!RoleMode)return fchflags(fd,flags);FlagCalls++;int index=RoleIndex(fd);if(index<0){errno=EINVAL;return -1;}if(FlagCalls!=IgnoreFlagCall)Roles[index].flags=flags;return 0;}
static int FaultSync(int fd){if(FaultEffect())return -1;return fsync(fd);}
static int RoleStat(int fd,struct stat *node){if(RoleMode&&++StatCalls==FailStatCall){errno=EIO;return -1;}int result=fstat(fd,node);if(!result&&RoleMode){int index=RoleIndex(fd);if(index>=0){node->st_uid=Roles[index].owner;node->st_gid=Roles[index].group;node->st_mode=(node->st_mode&~07777)|Roles[index].mode;node->st_flags=Roles[index].flags;}}return result;}
static int FaultAtStat(int fd,const char *leaf,struct stat *node,int flags){if(RoleMode&&++AtStatCalls==FailAtStatCall){errno=EIO;return -1;}return fstatat(fd,leaf,node,flags);}
#define fchmod FaultChmod
#define fchown FaultChown
#define fsync FaultSync
#define fstat RoleStat
#define fchflags FaultFlags
#define fstatat FaultAtStat
#include "RBXStorageGate.h"
#undef fchmod
#undef fchown
#undef fsync
#undef fstat
#undef fchflags
#undef fstatat
#define CHECK(x) do{Checks++;if(!(x)){fprintf(stderr,"FAIL line %d errno=%d\n",__LINE__,errno);exit(1);}}while(0)
static bool Authorize(void *unused){(void)unused;return ++Authorizations!=RevokeAt;}
static bool Transition(RBXStorageGateDirectory *e,size_t n,size_t selected){Authorizations=0;return RBXStorageGateDirectoryTransition(e,n,selected,geteuid(),getegid(),geteuid(),getegid(),Authorize,NULL);}
static RBXStorageGateDirectory *Watched;
static const size_t *Chosen;
static size_t WatchedCount,ChosenCount;
static bool ObservedSafe;
static int RebindDestination,RebindSource;
static size_t *MutableSelection;
static bool AuthorizeRebinding(void *unused){
    (void)unused;Authorizations++;
    if(Authorizations==1){CHECK(dup2(RebindSource,RebindDestination)==RebindDestination);MutableSelection[0]=4096;}
    return true;
}
static bool AuthorizeSet(void *unused){
    (void)unused;Authorizations++;size_t openCount=Authorizations/2;
    for(size_t i=0;i<WatchedCount;i++){
        bool open=false;for(size_t j=0;j<ChosenCount;j++)if(Chosen[j]==i&&j<openCount)open=true;
        int index=RoleIndex(Watched[i].directory);
        if(index<0||Roles[index].owner!=(open?AppRole:RootRole)||Roles[index].group!=(open?AppGroup:RootGroup))ObservedSafe=false;
    }
    return Authorizations!=RevokeAt;
}
static bool SetTransition(RBXStorageGateDirectory *entries,size_t count,const size_t *selected,size_t selectedCount){
    Watched=entries;WatchedCount=count;Chosen=selected;ChosenCount=selectedCount;Authorizations=Effects=0;ObservedSafe=true;
    return RBXStorageGateDirectorySetTransition(entries,count,selected,selectedCount,RootRole,RootGroup,AppRole,AppGroup,AuthorizeSet,NULL);
}
static void ResetRoles(RBXStorageGateDirectory *entries,size_t count){
    RoleCount=count;RoleMode=false;FailEffect=PersistentFault=Effects=0;RevokeAt=0;
    FlagCalls=IgnoreFlagCall=StatCalls=FailStatCall=AtStatCalls=FailAtStatCall=0;
    for(size_t i=0;i<count;i++){struct stat node;CHECK(fstat(entries[i].directory,&node)==0);CHECK(fchmod(entries[i].directory,0755)==0);Roles[i]=(Role){node.st_dev,node.st_ino,AppRole,AppGroup,0755,0};}
    RoleMode=true;
}
static void CheckRoles(RBXStorageGateDirectory *entries,size_t count,const size_t *selected,size_t selectedCount){
    for(size_t i=0;i<count;i++){
        bool open=false;for(size_t j=0;j<selectedCount;j++)if(selected[j]==i)open=true;
        int index=RoleIndex(entries[i].directory);CHECK(index>=0);CHECK(Roles[index].owner==(open?AppRole:RootRole));CHECK(Roles[index].group==(open?AppGroup:RootGroup));
        struct stat physical;CHECK(fstat(entries[i].directory,&physical)==0);CHECK(physical.st_uid==geteuid()&&physical.st_gid==getegid());CHECK((physical.st_mode&07777)==0700);
    }
}
static void Inspect(RBXStorageGateDirectory *e,size_t n){
    for(size_t i=0;i<n;i++){
        struct stat s;CHECK(fstat(e[i].directory,&s)==0);CHECK((s.st_mode&07777)==0700);
        int fd=openat(e[i].directory,"marker",O_RDONLY|O_NOFOLLOW);char bytes[16]={0};
        CHECK(fd>=0);CHECK(read(fd,bytes,sizeof(bytes))==11);CHECK(!memcmp(bytes,"own-canary\n",11));close(fd);
    }
}
static RBXStorageGateImmutableDirectory *ImmutableWatched;
static void ResetImmutable(RBXStorageGateDirectory *entries,RBXStorageGateImmutableDirectory *immutable,size_t count){
    ResetRoles(entries,count);const unsigned int flags[]={0,UF_NODUMP,UF_HIDDEN,UF_NODUMP|UF_HIDDEN};
    for(size_t i=0;i<count;i++){immutable[i]=(RBXStorageGateImmutableDirectory){entries[i],flags[i%4],false};Roles[i].flags=flags[i%4];}
}
static bool AuthorizeImmutable(void *unused){
    (void)unused;Authorizations++;size_t openCount=Authorizations/2;
    for(size_t i=0;i<WatchedCount;i++){
        bool open=false;for(size_t j=0;j<ChosenCount;j++)if(Chosen[j]==i&&j<openCount)open=true;
        int index=RoleIndex(ImmutableWatched[i].pin.directory);
        if(index<0||Roles[index].owner!=(open?AppRole:RootRole)||Roles[index].group!=(open?AppGroup:RootGroup)||
           Roles[index].mode!=(open?0700:0000)||Roles[index].flags!=(ImmutableWatched[i].originalFlags|(open?0:UF_IMMUTABLE)))ObservedSafe=false;
    }
    return Authorizations!=RevokeAt;
}
static bool ImmutableTransition(RBXStorageGateImmutableDirectory *entries,size_t count,const size_t *selected,size_t selectedCount){
    ImmutableWatched=entries;WatchedCount=count;Chosen=selected;ChosenCount=selectedCount;Authorizations=Effects=0;ObservedSafe=true;
    return RBXStorageGateImmutableDirectorySetTransition(entries,count,selected,selectedCount,RootRole,RootGroup,AppRole,AppGroup,AuthorizeImmutable,NULL);
}
static void CheckImmutable(RBXStorageGateImmutableDirectory *entries,size_t count,const size_t *selected,size_t selectedCount){
    for(size_t i=0;i<count;i++){
        bool open=false;for(size_t j=0;j<selectedCount;j++)if(selected[j]==i)open=true;
        int index=RoleIndex(entries[i].pin.directory);CHECK(index>=0);CHECK(Roles[index].owner==(open?AppRole:RootRole));CHECK(Roles[index].group==(open?AppGroup:RootGroup));
        CHECK(Roles[index].mode==(open?0700:0000));CHECK(Roles[index].flags==(entries[i].originalFlags|(open?0:UF_IMMUTABLE)));
        struct stat physical;CHECK(fstat(entries[i].pin.directory,&physical)==0);CHECK(physical.st_uid==geteuid()&&physical.st_gid==getegid());CHECK((physical.st_mode&07777)==0700&&physical.st_flags==0);
    }
}
static int HostImmutableFD=-1;
static bool HostOwnershipDenial;
static void RestoreHostFlags(void){if(HostImmutableFD>=0){fchflags(HostImmutableFD,0);fchmod(HostImmutableFD,0700);close(HostImmutableFD);HostImmutableFD=-1;}}
static void CheckHostImmutable(const char *base){
    // Real host inode/flags probe, separate from modeled distinct UID roles.
    // Retain a descriptor and register cleanup before adding any real flags.
    char path[4096];snprintf(path,sizeof(path),"%s/host-immutable",base);CHECK(mkdir(path,0700)==0);
    HostImmutableFD=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);CHECK(HostImmutableFD>=0);CHECK(atexit(RestoreHostFlags)==0);
    gid_t groups[256],differentGroup=getegid();int groupCount=getgroups(256,groups);CHECK(groupCount>=0);
    for(int i=0;i<groupCount;i++)if(groups[i]!=getegid()){differentGroup=groups[i];break;}
    // A same-owner chown may succeed as a no-op on macOS. Prove this host can
    // make a REAL group change before attributing its later denial to the flag.
    if(differentGroup!=getegid()){
        CHECK(fchown(HostImmutableFD,geteuid(),differentGroup)==0);struct stat baseline;
        CHECK(fstat(HostImmutableFD,&baseline)==0&&baseline.st_gid==differentGroup);
        CHECK(fchown(HostImmutableFD,geteuid(),getegid())==0);
    }
    CHECK(fchmod(HostImmutableFD,0000)==0);CHECK(fchflags(HostImmutableFD,UF_IMMUTABLE)==0);CHECK(fsync(HostImmutableFD)==0);
    struct stat node;CHECK(fstat(HostImmutableFD,&node)==0);CHECK((node.st_mode&07777)==0000&&node.st_flags==UF_IMMUTABLE);
    errno=0;CHECK(fchmod(HostImmutableFD,0777)==-1&&errno==EPERM);
    if(differentGroup!=getegid()){errno=0;CHECK(fchown(HostImmutableFD,geteuid(),differentGroup)==-1&&errno==EPERM);HostOwnershipDenial=true;}
    CHECK(fstat(HostImmutableFD,&node)==0);CHECK((node.st_mode&07777)==0000&&node.st_flags==UF_IMMUTABLE);
    CHECK(fchflags(HostImmutableFD,0)==0);CHECK(fchmod(HostImmutableFD,0700)==0);CHECK(fsync(HostImmutableFD)==0);RestoreHostFlags();CHECK(rmdir(path)==0);
}
static RBXStorageGateImmutableNode *NodeWatched;
static void ResetNodes(RBXStorageGateImmutableNode *nodes,size_t count){
    RoleMode=false;RoleCount=count;FailEffect=PersistentFault=Effects=0;RevokeAt=0;FlagCalls=IgnoreFlagCall=StatCalls=FailStatCall=AtStatCalls=FailAtStatCall=0;
    for(size_t i=0;i<count;i++){
        CHECK(fchmod(nodes[i].descriptor,0755)==0);nodes[i].ownsImmutable=false;
        Roles[i]=(Role){nodes[i].device,nodes[i].inode,AppRole,AppGroup,0755,nodes[i].originalFlags};
    }
    RoleMode=true;
}
static bool NodeMatches(const RBXStorageGateImmutableNode *entry,bool open){
    int index=RoleIndex(entry->descriptor);if(index<0)return false;
    return Roles[index].owner==(open?entry->activeOwner:RootRole)&&Roles[index].group==(open?entry->activeGroup:RootGroup)&&
        Roles[index].mode==(open?entry->activeMode:entry->sealedMode)&&Roles[index].flags==(entry->originalFlags|(open?0:UF_IMMUTABLE));
}
static bool AuthorizeNodes(void *unused){
    (void)unused;Authorizations++;size_t openCount=Authorizations/2;
    for(size_t i=0;i<WatchedCount;i++){
        bool open=false;for(size_t j=0;j<ChosenCount;j++)if(Chosen[j]==i&&j<openCount)open=true;
        if(!NodeMatches(&NodeWatched[i],open))ObservedSafe=false;
    }
    return Authorizations!=RevokeAt;
}
static bool NodeTransition(RBXStorageGateImmutableNode *nodes,size_t count,const size_t *selected,size_t selectedCount){
    NodeWatched=nodes;WatchedCount=count;Chosen=selected;ChosenCount=selectedCount;Authorizations=Effects=0;ObservedSafe=true;
    return RBXStorageGateImmutableNodeSetTransition(nodes,count,selected,selectedCount,RootRole,RootGroup,AppRole,AuthorizeNodes,NULL);
}
static void CheckNodes(RBXStorageGateImmutableNode *nodes,size_t count,const size_t *selected,size_t selectedCount){
    for(size_t i=0;i<count;i++){
        bool open=false;for(size_t j=0;j<selectedCount;j++)if(selected[j]==i)open=true;
        CHECK(NodeMatches(&nodes[i],open));struct stat physical;CHECK(fstat(nodes[i].descriptor,&physical)==0);
        CHECK(physical.st_uid==geteuid()&&physical.st_gid==getegid()&&physical.st_flags==0);
        mode_t expected=open?nodes[i].activeMode:(nodes[i].sealedMode?:0700);CHECK((physical.st_mode&07777)==expected);
        int fd=nodes[i].directory?openat(nodes[i].descriptor,"marker",O_RDONLY|O_NOFOLLOW):dup(nodes[i].descriptor);CHECK(fd>=0);
        char content[11];CHECK(pread(fd,content,sizeof(content),0)==11);CHECK(!memcmp(content,"own-canary\n",11));close(fd);
    }
}
static int RebindParentDestination,RebindParentSource;
static char *MutableLeaf;
static bool AuthorizeNodeRebinding(void *unused){
    (void)unused;Authorizations++;
    if(Authorizations==1){CHECK(dup2(RebindParentSource,RebindParentDestination)==RebindParentDestination);MutableLeaf[0]='X';MutableSelection[0]=4096;}
    return true;
}
static void CheckGenericNodes(const char *base,RBXStorageGateDirectory *directories){
    RoleMode=false;int parentFD=open(base,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);CHECK(parentFD>=0);struct stat parentNode;CHECK(fstat(parentFD,&parentNode)==0);
    RBXStorageGateDirectory parent={parentFD,parentNode.st_dev,parentNode.st_ino};RBXStorageGateImmutableNode nodes[6];
    char leaves[6][32];const mode_t activeModes[]={0755,0640,0700,0600,0711,0644};
    for(size_t i=0;i<6;i++){
        bool directory=i%2==0;int fd;
        if(directory){snprintf(leaves[i],sizeof(leaves[i]),"profile-%zu",i);fd=dup(directories[i].directory);}
        else {snprintf(leaves[i],sizeof(leaves[i]),"default-file-%zu",i);fd=openat(parentFD,leaves[i],O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0600);CHECK(fd>=0);CHECK(write(fd,"own-canary\n",11)==11);}
        CHECK(fd>=0);struct stat s;CHECK(fstat(fd,&s)==0);
        nodes[i]=(RBXStorageGateImmutableNode){fd,s.st_dev,s.st_ino,directory,parent,leaves[i],i==3?RootRole:AppRole,i==3?RootGroup:AppGroup,activeModes[i],0000,i%2?UF_NODUMP:UF_HIDDEN,false};
    }
    const size_t selection[]={0,1,3};ResetNodes(nodes,6);CHECK(NodeTransition(nodes,6,selection,3));CHECK(ObservedSafe&&Authorizations==6);
    unsigned effects=Effects,stats=StatCalls,atStats=AtStatCalls;CHECK(effects==54&&FlagCalls==9);CheckNodes(nodes,6,selection,3);
    for(unsigned fault=1;fault<=effects;fault++){
        ResetNodes(nodes,6);FailEffect=fault;CHECK(!NodeTransition(nodes,6,selection,3));CHECK(ObservedSafe);CheckNodes(nodes,6,NULL,0);
    }
    for(unsigned fault=1;fault<=stats;fault++){
        ResetNodes(nodes,6);FailStatCall=fault;CHECK(!NodeTransition(nodes,6,selection,3));CHECK(ObservedSafe);if(Effects)CheckNodes(nodes,6,NULL,0);
    }
    for(unsigned fault=1;fault<=atStats;fault++){
        ResetNodes(nodes,6);FailAtStatCall=fault;CHECK(!NodeTransition(nodes,6,selection,3));CHECK(ObservedSafe);if(Effects)CheckNodes(nodes,6,NULL,0);
    }
    for(unsigned fault=1;fault<=9;fault++){
        ResetNodes(nodes,6);IgnoreFlagCall=fault;CHECK(!NodeTransition(nodes,6,selection,3));CHECK(ObservedSafe);CheckNodes(nodes,6,NULL,0);
    }
    for(unsigned revoked=1;revoked<=6;revoked++){
        ResetNodes(nodes,6);RevokeAt=revoked;CHECK(!NodeTransition(nodes,6,selection,3));CHECK(ObservedSafe&&Authorizations==revoked);CheckNodes(nodes,6,NULL,0);
    }
    ResetNodes(nodes,6);CHECK(NodeTransition(nodes,6,NULL,0));CheckNodes(nodes,6,NULL,0);
    CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);for(size_t i=0;i<6;i++)nodes[i].ownsImmutable=true;
    CHECK(NodeTransition(nodes,6,selection,3));CHECK(Effects==24&&ObservedSafe);CheckNodes(nodes,6,selection,3);
    ResetNodes(nodes,6);CHECK(!RBXStorageGateImmutableNodeSetTransition(nodes,6,selection,3,RootRole,RootGroup,AppRole,NULL,NULL));CheckNodes(nodes,6,NULL,0);
    ResetNodes(nodes,6);const size_t duplicate[]={1,1},outside[]={6};CHECK(!NodeTransition(nodes,6,duplicate,2)&&Effects==0);
    CHECK(!NodeTransition(nodes,6,outside,1)&&Effects==0);CHECK(!NodeTransition(nodes,6,NULL,1)&&Effects==0);CHECK(!NodeTransition(nodes,6,selection,0)&&Effects==0);
    RBXStorageGateImmutableNode saved=nodes[1];nodes[1]=nodes[0];CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    nodes[1].directory=true;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    nodes[1].activeMode=04755;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    nodes[1].sealedMode=0711;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    nodes[1].activeOwner=AppRole+1;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    nodes[1].originalFlags|=UF_APPEND;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    unsigned int recordedFlags=Roles[1].flags;Roles[1].flags|=UF_IMMUTABLE;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);CHECK(Roles[1].flags==(recordedFlags|UF_IMMUTABLE));Roles[1].flags=recordedFlags;
    nodes[1].parent.inode++;CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;
    const char *badLeaves[]={NULL,"",".","..","profile-0/marker","missing",leaves[3]};
    for(size_t i=0;i<sizeof(badLeaves)/sizeof(*badLeaves);i++){nodes[1].leaf=badLeaves[i];CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;}
    RoleMode=false;CHECK(linkat(parentFD,leaves[1],parentFD,"hardlink-file",0)==0);RoleMode=true;
    CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);RoleMode=false;CHECK(unlinkat(parentFD,"hardlink-file",0)==0);
    CHECK(symlinkat(leaves[1],parentFD,"symlink-file")==0);RoleMode=true;nodes[1].leaf="symlink-file";CHECK(!NodeTransition(nodes,6,selection,3)&&Effects==0);nodes[1]=saved;RoleMode=false;CHECK(unlinkat(parentFD,"symlink-file",0)==0);
    // A data file below another inventoried root is rejected, including when
    // that child is a regular file rather than a directory.
    int marker=openat(nodes[0].descriptor,"marker",O_RDONLY|O_NOFOLLOW);CHECK(marker>=0);struct stat markerNode;CHECK(fstat(marker,&markerNode)==0);
    RBXStorageGateImmutableNode overlap[2]={nodes[0],{marker,markerNode.st_dev,markerNode.st_ino,false,directories[0],"marker",AppRole,AppGroup,0600,0000,0,false}};
    ResetNodes(overlap,2);CHECK(!NodeTransition(overlap,2,NULL,0)&&Effects==0);close(marker);
    // Parent fd, basename and selection are owned copies after validation.
    ResetNodes(nodes,6);int heldParent=dup(parentFD);CHECK(heldParent>=0);RebindParentDestination=parentFD;RebindParentSource=directories[8].directory;
    MutableLeaf=leaves[0];size_t mutableSelection[]={0,1,3};MutableSelection=mutableSelection;Authorizations=0;
    CHECK(RBXStorageGateImmutableNodeSetTransition(nodes,6,mutableSelection,3,RootRole,RootGroup,AppRole,AuthorizeNodeRebinding,NULL));CHECK(Authorizations==6);
    CHECK(dup2(heldParent,parentFD)==parentFD);close(heldParent);leaves[0][0]='p';CheckNodes(nodes,6,selection,3);
    // A separate namespace close-only inventory keeps traversal but blocks
    // mutation; it is not mixed with descendant protected data nodes.
    RBXStorageGateImmutableNode namespaceNode=nodes[0];namespaceNode.sealedMode=0711;ResetNodes(&namespaceNode,1);
    CHECK(NodeTransition(&namespaceNode,1,NULL,0));CheckNodes(&namespaceNode,1,NULL,0);
    namespaceNode.ownsImmutable=true;CHECK(NodeTransition(&namespaceNode,1,NULL,0));CHECK(Effects==1);CheckNodes(&namespaceNode,1,NULL,0);
    ResetNodes(nodes,6);PersistentFault=2;CHECK(!NodeTransition(nodes,6,selection,3));CHECK(Effects==13&&Authorizations==0&&Roles[0].owner==AppRole);
    PersistentFault=0;CHECK(NodeTransition(nodes,6,NULL,0));CheckNodes(nodes,6,NULL,0);RoleMode=false;
    for(size_t i=0;i<6;i++)close(nodes[i].descriptor);close(parentFD);
    printf("PASS generic immutable nodes 3 directories/3 files/%u effect faults/%u stat faults/%u parent-link faults/9 false-success flag writes/6 revocations; active attributes, parent bindings, file hard links, namespace0711 checked\n",effects,stats,atStats);
}
int main(int argc,char **argv){
    CHECK(argc==2);RootRole=geteuid();RootGroup=getegid();AppRole=RootRole+1;AppGroup=RootGroup+1;RBXStorageGateDirectory e[40];
    for(unsigned i=0;i<40;i++){
        char path[4096];snprintf(path,sizeof(path),"%s/profile-%u",argv[1],i);CHECK(mkdir(path,0700)==0);
        e[i].directory=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);CHECK(e[i].directory>=0);
        struct stat s;CHECK(fstat(e[i].directory,&s)==0);e[i].device=s.st_dev;e[i].inode=s.st_ino;
        int fd=openat(e[i].directory,"marker",O_WRONLY|O_CREAT|O_EXCL,0600);CHECK(fd>=0);CHECK(write(fd,"own-canary\n",11)==11);close(fd);
    }
    for(unsigned round=0;round<3;round++)for(unsigned selected=0;selected<40;selected++){CHECK(Transition(e,40,selected));Inspect(e,40);}
    for(unsigned stage=1;stage<=2;stage++){RevokeAt=stage;CHECK(!Transition(e,40,3));Inspect(e,40);}RevokeAt=0;
    // Inject failure at each chmod before/after owner changes, including opening
    // the selected directory. Later directories must still receive seal attempts.
    for(unsigned fault=1;fault<=82;fault++){
        CHECK(Transition(e,40,40));Calls=0;FailCall=fault;CHECK(!Transition(e,40,3));FailCall=0;
        CHECK(Transition(e,40,40));Inspect(e,40);
    }
    CHECK(!RBXStorageGateDirectoryTransition(e,40,0,geteuid(),getegid(),geteuid(),getegid(),NULL,NULL));Inspect(e,40);
    RBXStorageGateDirectory saved=e[4];e[4]=e[3];CHECK(!Transition(e,40,0));e[4]=saved;
    e[0].inode++;CHECK(!Transition(e,40,0));e[0].inode--;
    CHECK(!Transition(e,40,41));CHECK(!Transition(e,0,0));
    // Distinct logical owners are recorded while real host ownership is kept.
    // These assertions establish transition ordering, never cross-UID denial.
    const size_t selected[]={1,3,5};ResetRoles(e,6);
    CHECK(SetTransition(e,6,selected,3));CHECK(Authorizations==6&&ObservedSafe);unsigned effectCount=Effects;CHECK(effectCount==36);CheckRoles(e,6,selected,3);Inspect(e,6);
    for(unsigned fault=1;fault<=effectCount;fault++){
        ResetRoles(e,6);FailEffect=fault;CHECK(!SetTransition(e,6,selected,3));CHECK(ObservedSafe);CHECK(Effects>=24);CheckRoles(e,6,NULL,0);Inspect(e,6);
    }
    for(unsigned revoked=1;revoked<=6;revoked++){
        ResetRoles(e,6);RevokeAt=revoked;CHECK(!SetTransition(e,6,selected,3));CHECK(ObservedSafe&&Authorizations==revoked);CheckRoles(e,6,NULL,0);Inspect(e,6);
    }
    ResetRoles(e,6);CHECK(RBXStorageGateDirectorySetTransition(e,6,NULL,0,RootRole,RootGroup,AppRole,AppGroup,NULL,NULL));CHECK(Effects==24);CheckRoles(e,6,NULL,0);
    ResetRoles(e,6);CHECK(!RBXStorageGateDirectorySetTransition(e,6,selected,3,RootRole,RootGroup,AppRole,AppGroup,NULL,NULL));CheckRoles(e,6,NULL,0);
    const size_t duplicate[]={1,1},outside[]={6};
    ResetRoles(e,6);CHECK(!SetTransition(e,6,duplicate,2)&&Effects==0&&Authorizations==0);
    CHECK(!SetTransition(e,6,outside,1)&&Effects==0&&Authorizations==0);
    CHECK(!SetTransition(e,6,NULL,1)&&Effects==0&&Authorizations==0);
    CHECK(!SetTransition(e,6,selected,7)&&Effects==0&&Authorizations==0);
    CHECK(!SetTransition(e,6,selected,0)&&Effects==0&&Authorizations==0);
    saved=e[4];e[4]=e[3];CHECK(!SetTransition(e,6,selected,3)&&Effects==0&&Authorizations==0);e[4]=saved;
    int alias=dup(e[3].directory);CHECK(alias>=0);e[4]=(RBXStorageGateDirectory){alias,e[3].device,e[3].inode};CHECK(!SetTransition(e,6,selected,3)&&Effects==0&&Authorizations==0);e[4]=saved;close(alias);
    e[0].inode++;CHECK(!SetTransition(e,6,selected,3)&&Effects==0&&Authorizations==0);e[0].inode--;
    saved=e[0];e[0].directory=-1;CHECK(!SetTransition(e,6,selected,3)&&Effects==0&&Authorizations==0);e[0]=saved;
    int file=openat(e[0].directory,"marker",O_RDONLY|O_NOFOLLOW);CHECK(file>=0);struct stat fileNode;CHECK(fstat(file,&fileNode)==0);e[0]=(RBXStorageGateDirectory){file,fileNode.st_dev,fileNode.st_ino};CHECK(!SetTransition(e,6,selected,3)&&Effects==0&&Authorizations==0);e[0]=saved;close(file);
    // Input arrays and caller fd numbers cannot redirect an accepted operation.
    ResetRoles(e,6);int held=dup(e[1].directory);CHECK(held>=0);RebindDestination=e[1].directory;RebindSource=e[8].directory;size_t mutableSelection[]={1,3,5};MutableSelection=mutableSelection;Authorizations=0;
    CHECK(RBXStorageGateDirectorySetTransition(e,6,mutableSelection,3,RootRole,RootGroup,AppRole,AppGroup,AuthorizeRebinding,NULL));
    CHECK(Authorizations==6&&mutableSelection[0]==4096);CHECK(dup2(held,e[1].directory)==e[1].directory);close(held);CheckRoles(e,6,selected,3);Inspect(e,6);
    // Root + its descendant overlap even when reached through distinct FDs.
    RoleMode=false;CHECK(mkdirat(e[0].directory,"nested",0700)==0);int nested=openat(e[0].directory,"nested",O_RDONLY|O_DIRECTORY|O_NOFOLLOW);CHECK(nested>=0);struct stat nestedNode;CHECK(fstat(nested,&nestedNode)==0);
    RBXStorageGateDirectory overlap[]={e[0],{nested,nestedNode.st_dev,nestedNode.st_ino}};const size_t first[]={0};
    ResetRoles(overlap,2);CHECK(!SetTransition(overlap,2,first,1)&&Effects==0&&Authorizations==0);
    RBXStorageGateDirectory reversed[]={overlap[1],overlap[0]};CHECK(!SetTransition(reversed,2,first,1)&&Effects==0&&Authorizations==0);
    // Legacy close-all intentionally accepts parent/data/groups inventories.
    RoleMode=false;CHECK(Transition(overlap,2,2));close(nested);
    ResetRoles(e,6);PersistentFault=2;CHECK(!SetTransition(e,6,selected,3));CHECK(Authorizations==0);CHECK(Effects==13);CHECK(Roles[0].owner==AppRole);
    PersistentFault=0;CHECK(SetTransition(e,6,NULL,0));CheckRoles(e,6,NULL,0);RoleMode=false;
    RBXStorageGateImmutableDirectory immutable[6];
    ResetImmutable(e,immutable,6);CHECK(ImmutableTransition(immutable,6,selected,3));CHECK(ObservedSafe&&Authorizations==6);
    unsigned immutableEffects=Effects,immutableStats=StatCalls;CHECK(immutableEffects==54);CHECK(FlagCalls==9);CheckImmutable(immutable,6,selected,3);Inspect(e,6);
    for(unsigned fault=1;fault<=immutableEffects;fault++){
        ResetImmutable(e,immutable,6);FailEffect=fault;CHECK(!ImmutableTransition(immutable,6,selected,3));CHECK(ObservedSafe);CheckImmutable(immutable,6,NULL,0);Inspect(e,6);
    }
    for(unsigned fault=1;fault<=immutableStats;fault++){
        ResetImmutable(e,immutable,6);FailStatCall=fault;CHECK(!ImmutableTransition(immutable,6,selected,3));CHECK(ObservedSafe);
        if(Effects)CheckImmutable(immutable,6,NULL,0);
    }
    for(unsigned fault=1;fault<=9;fault++){
        ResetImmutable(e,immutable,6);IgnoreFlagCall=fault;CHECK(!ImmutableTransition(immutable,6,selected,3));CHECK(ObservedSafe);CheckImmutable(immutable,6,NULL,0);
    }
    for(unsigned revoked=1;revoked<=6;revoked++){
        ResetImmutable(e,immutable,6);RevokeAt=revoked;CHECK(!ImmutableTransition(immutable,6,selected,3));CHECK(ObservedSafe&&Authorizations==revoked);CheckImmutable(immutable,6,NULL,0);
    }
    ResetImmutable(e,immutable,6);CHECK(RBXStorageGateImmutableDirectorySetTransition(immutable,6,NULL,0,RootRole,RootGroup,AppRole,AppGroup,NULL,NULL));CheckImmutable(immutable,6,NULL,0);
    // Exact prior journal-owned frozen state is reusable without thawing inactive
    // roots. Missing ownership refuses the entire operation before any effects.
    CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0&&Authorizations==0);
    for(size_t i=0;i<6;i++)immutable[i].ownsImmutable=true;
    CHECK(ImmutableTransition(immutable,6,selected,3));CHECK(ObservedSafe&&Effects==24);CheckImmutable(immutable,6,selected,3);
    CHECK(ImmutableTransition(immutable,6,NULL,0));CheckImmutable(immutable,6,NULL,0);
    Roles[0].mode=0700;CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0);Roles[0].mode=0000;
    Roles[0].owner=AppRole;CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0);Roles[0].owner=RootRole;
    Roles[0].group=AppGroup;CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0);Roles[0].group=RootGroup;
    const unsigned int foreignFlags[]={UF_IMMUTABLE,UF_APPEND,SF_IMMUTABLE,SF_APPEND,0x40000000};
    for(size_t i=0;i<sizeof(foreignFlags)/sizeof(*foreignFlags);i++){
        ResetImmutable(e,immutable,6);immutable[0].originalFlags=Roles[0].flags=foreignFlags[i];immutable[0].ownsImmutable=true;
        CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0&&Authorizations==0);
        ResetImmutable(e,immutable,6);Roles[0].flags=foreignFlags[i];CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0&&Authorizations==0);CHECK(Roles[0].flags==foreignFlags[i]);
    }
    ResetImmutable(e,immutable,6);CHECK(!RBXStorageGateImmutableDirectorySetTransition(immutable,6,selected,3,RootRole,RootGroup,AppRole,AppGroup,NULL,NULL));CheckImmutable(immutable,6,NULL,0);
    ResetImmutable(e,immutable,6);CHECK(!ImmutableTransition(immutable,6,duplicate,2)&&Effects==0&&Authorizations==0);
    CHECK(!ImmutableTransition(immutable,6,outside,1)&&Effects==0);CHECK(!ImmutableTransition(immutable,6,NULL,1)&&Effects==0);
    CHECK(!ImmutableTransition(immutable,6,selected,0)&&Effects==0);CHECK(!ImmutableTransition(immutable,6,selected,7)&&Effects==0);
    immutable[4].pin=immutable[3].pin;CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0);immutable[4].pin=e[4];
    immutable[0].pin.inode++;CHECK(!ImmutableTransition(immutable,6,selected,3)&&Effects==0);immutable[0].pin.inode--;
    ResetImmutable(e,immutable,6);PersistentFault=2;CHECK(!ImmutableTransition(immutable,6,selected,3));CHECK(Authorizations==0&&Roles[0].owner==AppRole);CHECK(Effects==13);
    PersistentFault=0;CHECK(ImmutableTransition(immutable,6,NULL,0));CheckImmutable(immutable,6,NULL,0);RoleMode=false;
    CheckHostImmutable(argv[1]);
    RBXStorageGateImmutableNode genericNode;
    memset(&genericNode,0,sizeof(genericNode));
    CHECK(!RBXStorageGateImmutableNodeSetTransition(&genericNode,0,NULL,0,RootRole,RootGroup,AppRole,NULL,NULL));
    CheckGenericNodes(argv[1],e);
    for(unsigned i=0;i<40;i++)close(e[i].directory);
    printf("PASS %u directory gate assertions; legacy 40 profiles/120 selections/82 faults; selected set 3 of 6 roots/%u effect faults/6 revocations; host UID unchanged, selected-set roles modeled\n",Checks,effectCount);
    printf("PASS immutable set 3 of 6 roots/%u effect faults/%u stat faults/9 false-success flag writes/6 revocations; original flags preserved; host immutable denies chmod%s, restored\n",immutableEffects,immutableStats,HostOwnershipDenial?"/real chown change":" (no supplementary group for meaningful chown probe)");
}
