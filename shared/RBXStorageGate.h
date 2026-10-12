#pragma once
#include <sys/stat.h>
#include <sys/acl.h>
#include <unistd.h>
#include <errno.h>
#include <stdbool.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// SGATE-002: descriptor-pinned DAC primitive used by the storage authority.
// The authority supplies durable bindings and the process coordinator supplies admission.
// The caller proves registration/identity and process quiescence before opening
// these descriptors. This primitive neither invents that proof nor kills apps.
// Directory metadata remains observable; only traversal and execution are gated.
typedef struct {
    int executable, bundle, home;
    dev_t executableDevice, bundleDevice, homeDevice;
    ino_t executableInode, bundleInode, homeInode;
} RBXStorageGateEntry;

typedef bool (*RBXStorageGateAuthorization)(void *context);

// Logical profiles may share one executable. Bind their directory handles
// independently instead of repeatedly changing permissions on that executable.
// The coordinator must durably pin paths and drain every prior process/extension;
// permissions do not revoke previously opened descriptors or system brokers.
typedef struct {
    int directory;
    dev_t device;
    ino_t inode;
} RBXStorageGateDirectory;

static inline bool RBXStorageGateNoACL(int fd) {
    errno=0;
    acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    bool valid=acl_valid(acl)==0;
    acl_entry_t entry;
    errno=0;
    int result=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry),saved=errno;
    acl_free(acl);
    // Darwin returns 0 for an entry and -1/EINVAL at the end of a valid ACL.
    return valid && result==-1 && saved==EINVAL;
}

static inline bool RBXStorageGatePinned(int fd,dev_t device,ino_t inode,bool directory,
                                       uid_t privilegedOwner,uid_t appOwner,uid_t installerOwner) {
    struct stat s;
    if(fstat(fd,&s)!=0 || s.st_dev!=device || s.st_ino!=inode ||
       (directory?!S_ISDIR(s.st_mode):!S_ISREG(s.st_mode)) ||
       (!directory && s.st_nlink!=1) ||
       (s.st_uid!=privilegedOwner && s.st_uid!=appOwner && s.st_uid!=installerOwner) ||
       !RBXStorageGateNoACL(fd)) {errno=EPERM;return false;}
    return true;
}

static inline bool RBXStorageGateSet(int fd,uid_t owner,gid_t group,mode_t mode) {
    // Revoke execution before changing its owner. Conversely, admission grants
    // execution last, after data/bundle ownership is fully checked and flushed.
    if(fchmod(fd,mode)!=0 || fchown(fd,owner,group)!=0 || fchmod(fd,mode)!=0 || fsync(fd)!=0)return false;
    struct stat s;
    if(fstat(fd,&s)!=0)return false;
    if(s.st_uid!=owner || s.st_gid!=group || (s.st_mode&07777)!=mode){errno=EPERM;return false;}
    return true;
}

static inline bool RBXStorageGateSealDirectories(RBXStorageGateDirectory *entries,size_t count,
                                                uid_t owner,gid_t group) {
    bool ok=true;int first=0;
    for(size_t i=0;i<count;i++)if(!RBXStorageGateSet(entries[i].directory,owner,group,0700)){
        if(!first)first=errno;ok=false;
    }
    if(!ok)errno=first?:EIO;
    return ok;
}

// selected==count closes every directory. This is a DAC primitive, not a
// complete recovered-engine switch transaction or a license/launch authority.
static inline bool RBXStorageGateDirectoryTransition(RBXStorageGateDirectory *entries,size_t count,
    size_t selected,uid_t rootOwner,gid_t rootGroup,uid_t appOwner,gid_t appGroup,
    RBXStorageGateAuthorization authorized,void *context) {
    if(geteuid()!=rootOwner||!entries||!count||count>4096||selected>count){errno=EINVAL;return false;}
    for(size_t i=0;i<count;i++){
        RBXStorageGateDirectory e=entries[i];
        if(!RBXStorageGatePinned(e.directory,e.device,e.inode,true,rootOwner,appOwner,rootOwner))return false;
        for(size_t j=0;j<i;j++)if(entries[j].device==e.device&&entries[j].inode==e.inode){errno=EINVAL;return false;}
    }
    if(!RBXStorageGateSealDirectories(entries,count,rootOwner,rootGroup))return false;
    if(selected==count)return true;
    if(!authorized||!authorized(context)){errno=ECANCELED;return false;}
    bool ok=RBXStorageGateSet(entries[selected].directory,appOwner,appGroup,0700)&&authorized(context);
    if(!ok){int saved=errno?:ECANCELED;RBXStorageGateSealDirectories(entries,count,rootOwner,rootGroup);errno=saved;}
    return ok;
}

static inline int RBXStorageGateDirectoryOrder(const void *left,const void *right) {
    const RBXStorageGateDirectory *a=(const RBXStorageGateDirectory *)left,*b=(const RBXStorageGateDirectory *)right;
    if(a->device!=b->device)return a->device<b->device?-1:1;
    return a->inode==b->inode?0:(a->inode<b->inode?-1:1);
}

// Independent resource roots must not alias or contain one another. Walk real
// descriptor ancestors, not pathname prefixes. The transaction owner still
// keeps the namespace stable for the duration of this operation.
static inline bool RBXStorageGateDirectoriesDisjoint(RBXStorageGateDirectory *entries,size_t count) {
    if(!entries||!count||count>4096){errno=EINVAL;return false;}
    RBXStorageGateDirectory *ordered=(RBXStorageGateDirectory *)malloc(count*sizeof(*ordered));
    if(!ordered){errno=ENOMEM;return false;}
    for(size_t i=0;i<count;i++)ordered[i]=entries[i];
    qsort(ordered,count,sizeof(*ordered),RBXStorageGateDirectoryOrder);
    bool ok=true;int failure=0;
    for(size_t i=1;i<count;i++)if(!RBXStorageGateDirectoryOrder(&ordered[i-1],&ordered[i])){ok=false;failure=EINVAL;break;}
    size_t observations=0;
    for(size_t i=0;ok&&i<count;i++) {
        int current=fcntl(entries[i].directory,F_DUPFD_CLOEXEC,0);
        if(current<0){ok=false;failure=errno;break;}
        struct stat node;
        if(fstat(current,&node)){failure=errno;ok=false;}
        bool root=false;
        for(unsigned depth=0;ok&&!root&&depth<256;depth++) {
            // Bound unusual mount hierarchies and very large inventories.
            if(++observations>65536){failure=E2BIG;ok=false;break;}
            int parent=openat(current,"..",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(parent<0){failure=errno;ok=false;break;}
            struct stat ancestor;
            if(fstat(parent,&ancestor)||!S_ISDIR(ancestor.st_mode)){failure=errno?:EPERM;ok=false;close(parent);break;}
            root=node.st_dev==ancestor.st_dev&&node.st_ino==ancestor.st_ino;
            RBXStorageGateDirectory key={-1,ancestor.st_dev,ancestor.st_ino};
            if(!root&&bsearch(&key,ordered,count,sizeof(*ordered),RBXStorageGateDirectoryOrder)){failure=EINVAL;ok=false;}
            close(current);current=parent;node=ancestor;
        }
        if(ok&&!root){failure=ELOOP;ok=false;}
        close(current);
    }
    free(ordered);if(!ok)errno=failure?:EIO;return ok;
}

// Open one logical profile's disjoint resource roots (for example main data and
// app groups). selected contains unique inventory indices; NULL/0 closes all.
// Shape, inode, ACL and overlap errors are rejected before permission effects.
// After that validation, seal the COMPLETE inventory before asking for live
// authorization. Recheck authorization before and after EACH selected open.
// Every effect failure attempts a full reseal, including a failed initial seal.
// A false return does not prove closure if those cleanup syscalls also fail.
// Caller owns durable intent/recovery, immutable ancestry and process/launch
// exclusion. This synchronous primitive never supplies that authority itself.
// The older single-index API above keeps its existing nested close-all behavior.
static inline bool RBXStorageGateDirectorySetTransition(const RBXStorageGateDirectory *entries,size_t count,
    const size_t *selected,size_t selectedCount,uid_t rootOwner,gid_t rootGroup,uid_t appOwner,gid_t appGroup,
    RBXStorageGateAuthorization authorized,void *context) {
    if(geteuid()!=rootOwner||!entries||!count||count>4096||selectedCount>count||
       (selectedCount==0?selected!=NULL:selected==NULL)){errno=EINVAL;return false;}
    RBXStorageGateDirectory *pins=(RBXStorageGateDirectory *)calloc(count,sizeof(*pins));
    size_t *selection=selectedCount?(size_t *)malloc(selectedCount*sizeof(*selection)):NULL;
    if(!pins||(selectedCount&&!selection)){free(pins);free(selection);errno=ENOMEM;return false;}
    bool ok=false;int failure=0;size_t held=0;
    for(size_t i=0;i<selectedCount;i++) {
        if(selected[i]>=count){failure=EINVAL;goto finished;}
        selection[i]=selected[i];
        for(size_t j=0;j<i;j++)if(selection[j]==selection[i]){failure=EINVAL;goto finished;}
    }
    // Private duplicates survive a caller closing/reusing its original fd in
    // an authorization callback. Expected inode identities remain immutable.
    for(size_t i=0;i<count;i++) {
        pins[i]=entries[i];pins[i].directory=fcntl(entries[i].directory,F_DUPFD_CLOEXEC,0);
        if(pins[i].directory<0){failure=errno;goto finished;}held++;
        if(!RBXStorageGatePinned(pins[i].directory,pins[i].device,pins[i].inode,true,rootOwner,appOwner,rootOwner)){failure=errno;goto finished;}
    }
    if(!RBXStorageGateDirectoriesDisjoint(pins,count)){failure=errno;goto finished;}
    if(!RBXStorageGateSealDirectories(pins,count,rootOwner,rootGroup)){failure=errno;goto reseal;}
    for(size_t i=0;i<selectedCount;i++) {
        if(!authorized||!authorized(context)){failure=ECANCELED;goto reseal;}
        RBXStorageGateDirectory entry=pins[selection[i]];
        if(!RBXStorageGatePinned(entry.directory,entry.device,entry.inode,true,rootOwner,appOwner,rootOwner)||
           !RBXStorageGateSet(entry.directory,appOwner,appGroup,0700)){failure=errno;goto reseal;}
        if(!authorized(context)){failure=ECANCELED;goto reseal;}
    }
    ok=true;goto finished;
reseal:
    RBXStorageGateSealDirectories(pins,count,rootOwner,rootGroup);
finished:
    for(size_t i=0;i<held;i++)close(pins[i].directory);
    free(pins);free(selection);if(!ok)errno=failure?:EIO;return ok;
}

// The root-owned durable journal supplies originalFlags and ownsImmutable.
// ownsImmutable may be true ONLY for a freeze recorded by this authority; it is
// not permission to adopt or clear an unrelated application's immutable flags.
typedef struct {
    RBXStorageGateDirectory pin;
    unsigned int originalFlags;
    bool ownsImmutable;
} RBXStorageGateImmutableDirectory;

static inline bool RBXStorageGateImmutableRead(const RBXStorageGateImmutableDirectory *entry,
    uid_t rootOwner,uid_t appOwner,struct stat *node) {
    if(fstat(entry->pin.directory,node)||node->st_dev!=entry->pin.device||node->st_ino!=entry->pin.inode||
       !S_ISDIR(node->st_mode)||(node->st_uid!=rootOwner&&node->st_uid!=appOwner)||
       !RBXStorageGateNoACL(entry->pin.directory)){errno=EPERM;return false;}
    return true;
}

static inline bool RBXStorageGateImmutableState(const RBXStorageGateImmutableDirectory *entry,
    uid_t owner,gid_t group,mode_t mode,unsigned int flags) {
    struct stat node;
    if(!RBXStorageGateImmutableRead(entry,owner,owner,&node))return false;
    if(node.st_gid!=group||(node.st_mode&07777)!=mode||node.st_flags!=flags){errno=EPERM;return false;}
    return true;
}

static inline bool RBXStorageGateImmutableAdmissible(const RBXStorageGateImmutableDirectory *entry,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    // Keep harmless caller-recorded bits; refuse immutable/append/system and
    // unknown originals rather than silently stripping their protections.
    if(entry->originalFlags&~(UF_NODUMP|UF_HIDDEN)){errno=EPERM;return false;}
    struct stat node;
    if(!RBXStorageGateImmutableRead(entry,rootOwner,appOwner,&node))return false;
    if(node.st_flags==entry->originalFlags)return true;
    if(entry->ownsImmutable&&node.st_flags==(entry->originalFlags|UF_IMMUTABLE)&&
       node.st_uid==rootOwner&&node.st_gid==rootGroup&&(node.st_mode&07777)==0000)return true;
    errno=EPERM;return false;
}

static inline bool RBXStorageGateImmutableFreeze(const RBXStorageGateImmutableDirectory *entry,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    if(!RBXStorageGateImmutableAdmissible(entry,rootOwner,rootGroup,appOwner))return false;
    struct stat node;if(fstat(entry->pin.directory,&node))return false;
    if(node.st_flags==entry->originalFlags) {
        if(!RBXStorageGateSet(entry->pin.directory,rootOwner,rootGroup,0000)||
           fchflags(entry->pin.directory,entry->originalFlags|UF_IMMUTABLE))return false;
    }
    // An already frozen root is never thawed merely to refresh its closure.
    return fsync(entry->pin.directory)==0&&RBXStorageGateImmutableState(entry,rootOwner,rootGroup,0000,
                                                                       entry->originalFlags|UF_IMMUTABLE);
}

static inline bool RBXStorageGateImmutableFreezeAll(const RBXStorageGateImmutableDirectory *entries,size_t count,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    bool ok=true;int failure=0;
    for(size_t i=0;i<count;i++)if(!RBXStorageGateImmutableFreeze(&entries[i],rootOwner,rootGroup,appOwner)) {
        if(!failure)failure=errno;ok=false;
    }
    if(!ok)errno=failure?:EIO;return ok;
}

static inline bool RBXStorageGateImmutableThaw(const RBXStorageGateImmutableDirectory *entry,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner,gid_t appGroup) {
    if(!entry->ownsImmutable||!RBXStorageGateImmutableState(entry,rootOwner,rootGroup,0000,
                                                          entry->originalFlags|UF_IMMUTABLE))return false;
    if(fchflags(entry->pin.directory,entry->originalFlags)||fsync(entry->pin.directory)||
       !RBXStorageGateImmutableState(entry,rootOwner,rootGroup,0000,entry->originalFlags)||
       !RBXStorageGateSet(entry->pin.directory,appOwner,appGroup,0700))return false;
    return RBXStorageGateImmutableState(entry,appOwner,appGroup,0700,entry->originalFlags);
}

// Separate native-directory gate: inactive roots are root:group/0000 plus
// UF_IMMUTABLE; selected roots are app:group/0700 with only originalFlags.
// Freeze every resource before authorization, then thaw selected main/group
// roots with authorization before and after each. On ANY effect/auth failure,
// attempt to freeze the complete inventory and return false. Cleanup failure
// must keep the coordinator's launch fence closed; false never proves closure.
// Inputs are copied; aliases, overlaps, stale pins and foreign flags are refused
// before effects. The root journal must record freeze intent before calling and
// retain original flags/pins across restart. This does not drain processes or
// protect writable ancestors, retained FDs, keychain or external shared stores.
static inline bool RBXStorageGateImmutableDirectorySetTransition(
    const RBXStorageGateImmutableDirectory *entries,size_t count,const size_t *selected,size_t selectedCount,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner,gid_t appGroup,
    RBXStorageGateAuthorization authorized,void *context) {
    if(geteuid()!=rootOwner||!entries||!count||count>4096||selectedCount>count||
       (selectedCount==0?selected!=NULL:selected==NULL)){errno=EINVAL;return false;}
    RBXStorageGateImmutableDirectory *frozen=(RBXStorageGateImmutableDirectory *)calloc(count,sizeof(*frozen));
    RBXStorageGateDirectory *pins=(RBXStorageGateDirectory *)calloc(count,sizeof(*pins));
    size_t *selection=selectedCount?(size_t *)malloc(selectedCount*sizeof(*selection)):NULL;
    if(!frozen||!pins||(selectedCount&&!selection)){free(frozen);free(pins);free(selection);errno=ENOMEM;return false;}
    bool ok=false;int failure=0;size_t held=0;
    for(size_t i=0;i<selectedCount;i++) {
        if(selected[i]>=count){failure=EINVAL;goto immutable_finished;}
        selection[i]=selected[i];
        for(size_t j=0;j<i;j++)if(selection[j]==selection[i]){failure=EINVAL;goto immutable_finished;}
    }
    for(size_t i=0;i<count;i++) {
        frozen[i]=entries[i];frozen[i].pin.directory=fcntl(entries[i].pin.directory,F_DUPFD_CLOEXEC,0);
        if(frozen[i].pin.directory<0){failure=errno;goto immutable_finished;}held++;pins[i]=frozen[i].pin;
        if(!RBXStorageGateImmutableAdmissible(&frozen[i],rootOwner,rootGroup,appOwner)){failure=errno;goto immutable_finished;}
    }
    if(!RBXStorageGateDirectoriesDisjoint(pins,count)){failure=errno;goto immutable_finished;}
    // All pre-existing flag ownership has now been checked. From here cleanup
    // can recognize a freeze performed by this invocation, including after a
    // successful flag syscall followed by failed durability/readback.
    for(size_t i=0;i<count;i++)frozen[i].ownsImmutable=true;
    if(!RBXStorageGateImmutableFreezeAll(frozen,count,rootOwner,rootGroup,appOwner)){failure=errno;goto immutable_reseal;}
    for(size_t selectedIndex=0;selectedIndex<selectedCount;selectedIndex++) {
        if(!authorized||!authorized(context)){failure=ECANCELED;goto immutable_reseal;}
        if(!RBXStorageGateImmutableThaw(&frozen[selection[selectedIndex]],rootOwner,rootGroup,appOwner,appGroup)){failure=errno;goto immutable_reseal;}
        if(!authorized(context)){failure=ECANCELED;goto immutable_reseal;}
    }
    ok=true;goto immutable_finished;
immutable_reseal:
    RBXStorageGateImmutableFreezeAll(frozen,count,rootOwner,rootGroup,appOwner);
immutable_finished:
    for(size_t i=0;i<held;i++)close(frozen[i].pin.directory);
    free(frozen);free(pins);free(selection);if(!ok)errno=failure?:EIO;return ok;
}

// Generic native inventory entry. parent/leaf prove the descriptor's current
// namespace binding, including for regular files whose fd cannot open "..".
// All original/active attributes and prior immutable ownership come from the
// root journal. Active modes exclude set-id/sticky bits. Namespace directories
// can stay root-owned/0711/immutable in a SEPARATE close-only inventory; do not
// mix an ancestor with its descendants in one transition.
typedef struct {
    int descriptor;
    dev_t device;
    ino_t inode;
    bool directory;
    RBXStorageGateDirectory parent;
    const char *leaf;
    uid_t activeOwner;
    gid_t activeGroup;
    mode_t activeMode;
    mode_t sealedMode;
    unsigned int originalFlags;
    bool ownsImmutable;
} RBXStorageGateImmutableNode;

static inline bool RBXStorageGateNodeRead(const RBXStorageGateImmutableNode *entry,
    uid_t rootOwner,uid_t appOwner,struct stat *node) {
    struct stat parent,named;
    if(fstat(entry->descriptor,node)||fstat(entry->parent.directory,&parent)||
       fstatat(entry->parent.directory,entry->leaf,&named,AT_SYMLINK_NOFOLLOW)||
       node->st_dev!=entry->device||node->st_ino!=entry->inode||
       named.st_dev!=node->st_dev||named.st_ino!=node->st_ino||
       (entry->directory?!S_ISDIR(node->st_mode):(!S_ISREG(node->st_mode)||node->st_nlink!=1))||
       S_ISLNK(named.st_mode)||!S_ISDIR(parent.st_mode)||parent.st_dev!=entry->parent.device||parent.st_ino!=entry->parent.inode||
       (node->st_uid!=rootOwner&&node->st_uid!=appOwner)||
       (parent.st_uid!=rootOwner&&parent.st_uid!=appOwner)||
       !RBXStorageGateNoACL(entry->descriptor)||!RBXStorageGateNoACL(entry->parent.directory)){errno=EPERM;return false;}
    return true;
}

static inline bool RBXStorageGateNodeState(const RBXStorageGateImmutableNode *entry,
    uid_t rootOwner,uid_t appOwner,uid_t owner,gid_t group,mode_t mode,unsigned int flags) {
    struct stat node;
    if(!RBXStorageGateNodeRead(entry,rootOwner,appOwner,&node))return false;
    if(node.st_uid!=owner||node.st_gid!=group||(node.st_mode&07777)!=mode||node.st_flags!=flags){errno=EPERM;return false;}
    return true;
}

static inline bool RBXStorageGateNodeAdmissible(const RBXStorageGateImmutableNode *entry,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    if(!entry->leaf||!entry->leaf[0]||strnlen(entry->leaf,NAME_MAX+1)>NAME_MAX||
       strchr(entry->leaf,'/')||!strcmp(entry->leaf,".")||!strcmp(entry->leaf,"..")||
       (entry->originalFlags&~(UF_NODUMP|UF_HIDDEN))||(entry->activeMode&~0777)||
       (entry->activeOwner!=rootOwner&&entry->activeOwner!=appOwner)||
       (entry->sealedMode!=0000&&(!entry->directory||entry->sealedMode!=0711))){errno=EINVAL;return false;}
    struct stat node;
    if(!RBXStorageGateNodeRead(entry,rootOwner,appOwner,&node))return false;
    if(node.st_flags==entry->originalFlags)return true;
    if(entry->ownsImmutable&&node.st_flags==(entry->originalFlags|UF_IMMUTABLE)&&
       node.st_uid==rootOwner&&node.st_gid==rootGroup&&(node.st_mode&07777)==entry->sealedMode)return true;
    errno=EPERM;return false;
}

static inline bool RBXStorageGateNodesDisjoint(const RBXStorageGateImmutableNode *entries,size_t count) {
    RBXStorageGateDirectory *ordered=(RBXStorageGateDirectory *)malloc(count*sizeof(*ordered));
    if(!ordered){errno=ENOMEM;return false;}
    for(size_t i=0;i<count;i++)ordered[i]=(RBXStorageGateDirectory){entries[i].descriptor,entries[i].device,entries[i].inode};
    qsort(ordered,count,sizeof(*ordered),RBXStorageGateDirectoryOrder);
    bool ok=true;int failure=0;size_t observations=0;
    for(size_t i=1;i<count;i++)if(!RBXStorageGateDirectoryOrder(&ordered[i-1],&ordered[i])){ok=false;failure=EINVAL;break;}
    for(size_t i=0;ok&&i<count;i++) {
        int current=fcntl(entries[i].parent.directory,F_DUPFD_CLOEXEC,0);
        if(current<0){ok=false;failure=errno;break;}
        bool root=false;
        for(unsigned depth=0;ok&&!root&&depth<256;depth++) {
            if(++observations>65536){failure=E2BIG;ok=false;break;}
            struct stat node;if(fstat(current,&node)){failure=errno;ok=false;break;}
            RBXStorageGateDirectory key={-1,node.st_dev,node.st_ino};
            if(bsearch(&key,ordered,count,sizeof(*ordered),RBXStorageGateDirectoryOrder)){failure=EINVAL;ok=false;break;}
            int parent=openat(current,"..",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(parent<0){failure=errno;ok=false;break;}
            struct stat ancestor;if(fstat(parent,&ancestor)){failure=errno;ok=false;close(parent);break;}
            root=node.st_dev==ancestor.st_dev&&node.st_ino==ancestor.st_ino;
            close(current);current=parent;
        }
        if(ok&&!root){failure=ELOOP;ok=false;}
        close(current);
    }
    free(ordered);if(!ok)errno=failure?:EIO;return ok;
}

static inline bool RBXStorageGateNodeFreeze(const RBXStorageGateImmutableNode *entry,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    if(!RBXStorageGateNodeAdmissible(entry,rootOwner,rootGroup,appOwner))return false;
    struct stat node;if(fstat(entry->descriptor,&node))return false;
    if(node.st_flags==entry->originalFlags) {
        if(!RBXStorageGateSet(entry->descriptor,rootOwner,rootGroup,entry->sealedMode)||
           fchflags(entry->descriptor,entry->originalFlags|UF_IMMUTABLE))return false;
    }
    return fsync(entry->descriptor)==0&&RBXStorageGateNodeState(entry,rootOwner,appOwner,rootOwner,rootGroup,
                                                               entry->sealedMode,entry->originalFlags|UF_IMMUTABLE);
}

static inline bool RBXStorageGateNodesFreezeAll(const RBXStorageGateImmutableNode *entries,size_t count,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    bool ok=true;int failure=0;
    for(size_t i=0;i<count;i++)if(!RBXStorageGateNodeFreeze(&entries[i],rootOwner,rootGroup,appOwner)){
        if(!failure)failure=errno;ok=false;
    }
    if(!ok)errno=failure?:EIO;return ok;
}

static inline bool RBXStorageGateNodeThaw(const RBXStorageGateImmutableNode *entry,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner) {
    if(!entry->ownsImmutable||!RBXStorageGateNodeState(entry,rootOwner,appOwner,rootOwner,rootGroup,
                                                    entry->sealedMode,entry->originalFlags|UF_IMMUTABLE))return false;
    if(fchflags(entry->descriptor,entry->originalFlags)||fsync(entry->descriptor)||
       !RBXStorageGateNodeState(entry,rootOwner,appOwner,rootOwner,rootGroup,entry->sealedMode,entry->originalFlags)||
       !RBXStorageGateSet(entry->descriptor,entry->activeOwner,entry->activeGroup,entry->activeMode))return false;
    return RBXStorageGateNodeState(entry,rootOwner,appOwner,entry->activeOwner,entry->activeGroup,entry->activeMode,entry->originalFlags);
}

// Same freeze-all / authorize / selected-set / reseal contract as the immutable
// directory API, with explicit per-node active attributes and regular-file
// support. Leaf strings and both descriptor sets are privately copied. Regular
// files must have exactly one hard link. Any cleanup failure is still false;
// only the owning coordinator can keep launches fenced and recover its journal.
static inline bool RBXStorageGateImmutableNodeSetTransition(const RBXStorageGateImmutableNode *entries,size_t count,
    const size_t *selected,size_t selectedCount,uid_t rootOwner,gid_t rootGroup,uid_t appOwner,
    RBXStorageGateAuthorization authorized,void *context) {
    if(geteuid()!=rootOwner||!entries||!count||count>4096||selectedCount>count||
       (selectedCount==0?selected!=NULL:selected==NULL)){errno=EINVAL;return false;}
    RBXStorageGateImmutableNode *nodes=(RBXStorageGateImmutableNode *)calloc(count,sizeof(*nodes));
    size_t *selection=selectedCount?(size_t *)malloc(selectedCount*sizeof(*selection)):NULL;
    if(!nodes||(selectedCount&&!selection)){free(nodes);free(selection);errno=ENOMEM;return false;}
    for(size_t i=0;i<count;i++){nodes[i].descriptor=-1;nodes[i].parent.directory=-1;}
    bool ok=false;int failure=0;
    for(size_t i=0;i<selectedCount;i++) {
        if(selected[i]>=count){failure=EINVAL;goto node_finished;}selection[i]=selected[i];
        for(size_t j=0;j<i;j++)if(selection[j]==selection[i]){failure=EINVAL;goto node_finished;}
    }
    for(size_t i=0;i<count;i++) {
        if(!entries[i].leaf||strnlen(entries[i].leaf,NAME_MAX+1)>NAME_MAX){failure=EINVAL;goto node_finished;}
        nodes[i]=entries[i];nodes[i].descriptor=-1;nodes[i].parent.directory=-1;nodes[i].leaf=strdup(entries[i].leaf);
        if(!nodes[i].leaf){failure=ENOMEM;goto node_finished;}
        nodes[i].descriptor=fcntl(entries[i].descriptor,F_DUPFD_CLOEXEC,0);
        if(nodes[i].descriptor<0){failure=errno;goto node_finished;}
        nodes[i].parent.directory=fcntl(entries[i].parent.directory,F_DUPFD_CLOEXEC,0);
        if(nodes[i].parent.directory<0){failure=errno;goto node_finished;}
        if(!RBXStorageGateNodeAdmissible(&nodes[i],rootOwner,rootGroup,appOwner)){failure=errno;goto node_finished;}
    }
    if(!RBXStorageGateNodesDisjoint(nodes,count)){failure=errno;goto node_finished;}
    for(size_t i=0;i<count;i++)nodes[i].ownsImmutable=true;
    if(!RBXStorageGateNodesFreezeAll(nodes,count,rootOwner,rootGroup,appOwner)){failure=errno;goto node_reseal;}
    for(size_t pick=0;pick<selectedCount;pick++) {
        if(!authorized||!authorized(context)){failure=ECANCELED;goto node_reseal;}
        if(!RBXStorageGateNodeThaw(&nodes[selection[pick]],rootOwner,rootGroup,appOwner)){failure=errno;goto node_reseal;}
        if(!authorized(context)){failure=ECANCELED;goto node_reseal;}
    }
    ok=true;goto node_finished;
node_reseal:
    RBXStorageGateNodesFreezeAll(nodes,count,rootOwner,rootGroup,appOwner);
node_finished:
    for(size_t i=0;i<count;i++){if(nodes[i].descriptor>=0)close(nodes[i].descriptor);if(nodes[i].parent.directory>=0)close(nodes[i].parent.directory);free((void *)nodes[i].leaf);}
    free(nodes);free(selection);if(!ok)errno=failure?:EIO;return ok;
}

static inline bool RBXStorageGateSeal(RBXStorageGateEntry *entries,size_t count,
                                      uid_t owner,gid_t group) {
    bool ok=true;int first=0;
    // Never leave a later executable runnable just because an earlier seal failed.
    for(size_t i=0;i<count;i++)if(!RBXStorageGateSet(entries[i].executable,owner,group,0600)){
        if(!first)first=errno;ok=false;
    }
    for(size_t i=0;i<count;i++){
        if(!RBXStorageGateSet(entries[i].home,owner,group,0700)){if(!first)first=errno;ok=false;}
        if(!RBXStorageGateSet(entries[i].bundle,owner,group,0700)){if(!first)first=errno;ok=false;}
    }
    if(!ok)errno=first?:EIO;
    return ok;
}

// selected==count means CLOSED. Owner parameters let the host exercise real
// mode/inode operations without root; production supplies immutable 0/0,501/501,33.
// Host fixtures do not claim cross-UID enforcement; real clone probes do that.
static inline bool RBXStorageGateTransition(RBXStorageGateEntry *entries,size_t count,size_t selected,
    uid_t rootOwner,gid_t rootGroup,uid_t appOwner,gid_t appGroup,uid_t installerOwner,
    RBXStorageGateAuthorization authorized,void *context) {
    if(geteuid()!=rootOwner || !entries || count==0 || count>4096 || selected>count){errno=EINVAL;return false;}
    for(size_t i=0;i<count;i++){
        RBXStorageGateEntry e=entries[i];
        if(!RBXStorageGatePinned(e.executable,e.executableDevice,e.executableInode,false,rootOwner,appOwner,installerOwner) ||
           !RBXStorageGatePinned(e.bundle,e.bundleDevice,e.bundleInode,true,rootOwner,appOwner,installerOwner) ||
           !RBXStorageGatePinned(e.home,e.homeDevice,e.homeInode,true,rootOwner,appOwner,installerOwner))return false;
        if(e.homeDevice==e.bundleDevice && e.homeInode==e.bundleInode){errno=EINVAL;return false;}
        for(size_t j=0;j<i;j++){
            if((entries[j].homeDevice==e.homeDevice && entries[j].homeInode==e.homeInode) ||
               (entries[j].bundleDevice==e.bundleDevice && entries[j].bundleInode==e.bundleInode) ||
               (entries[j].executableDevice==e.executableDevice && entries[j].executableInode==e.executableInode) ||
               (entries[j].homeDevice==e.bundleDevice && entries[j].homeInode==e.bundleInode) ||
               (entries[j].bundleDevice==e.homeDevice && entries[j].bundleInode==e.homeInode)){
                errno=EINVAL;return false;
            }
        }
    }
    if(!RBXStorageGateSeal(entries,count,rootOwner,rootGroup))return false;
    if(selected==count)return true;
    // Admission is never allowed without a current operation/stop proof.
    if(!authorized || !authorized(context)){errno=ECANCELED;return false;}
    RBXStorageGateEntry e=entries[selected];
    bool ok=RBXStorageGateSet(e.home,appOwner,appGroup,0700) && authorized(context) &&
            RBXStorageGateSet(e.bundle,rootOwner,rootGroup,0755) && authorized(context) &&
            RBXStorageGateSet(e.executable,rootOwner,rootGroup,0755) && authorized(context);
    if(!ok){int saved=errno?:ECANCELED;RBXStorageGateSeal(entries,count,rootOwner,rootGroup);errno=saved;}
    return ok;
}
