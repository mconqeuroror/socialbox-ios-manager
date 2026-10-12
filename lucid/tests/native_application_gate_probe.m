// Pure protocol and owned-fixture tests. Never invokes a device/root gate.
#define main NativeApplicationGateProbeEntry
#include "../Switching/NativeApplicationGateProbe.m"
#undef main
static unsigned Checks;
#define CHECK(x) do{Checks++;if(!(x)){fprintf(stderr,"FAIL line %d errno %d\n",__LINE__,errno);exit(1);}}while(0)
int main(void){@autoreleasepool{
    NSString *uuid=@"01234567-89ab-cdef-0123-456789abcdef",*path=[Scope stringByAppendingPathComponent:uuid];
    CHECK(DirectoryArgument(path));CHECK(!DirectoryArgument(nil));CHECK(!DirectoryArgument([path uppercaseString]));
    for(NSString *bad in @[[path stringByAppendingString:@"/"],[Scope stringByAppendingFormat:@"//%@",uuid],
        [Scope stringByAppendingFormat:@"/../%@",uuid],[@"/private/var/mobile/" stringByAppendingString:uuid],
        [Scope stringByAppendingPathComponent:@"not-a-uuid"],[path stringByAppendingString:@"/child"]])CHECK(!DirectoryArgument(bad));
    NSMutableDictionary *payload=[@{@"formatVersion":@1,@"component":ProbeComponent,@"applicationGate":@{},@"phase":@"prepared",@"acceptance":@"FAIL",@"spawnErrno":@-1,
        @"probeAccountFileContentsRead":@NO,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO} mutableCopy];CHECK(Payload(payload));
    for(NSString *phase in @[@"closed",@"spawn-check-pending",@"spawn-checked",@"restoring",@"restored"]){payload[@"phase"]=phase;CHECK(Payload(payload));}
    payload[@"phase"]=@"arbitrary";CHECK(!Payload(payload));payload[@"phase"]=@"closed";
    for(id bad in @[@YES,@1.5,@-2,@5000,@"13"]){payload[@"spawnErrno"]=bad;CHECK(!Payload(payload));}payload[@"spawnErrno"]=@(EACCES);
    payload[@"formatVersion"]=@YES;CHECK(!Payload(payload));payload[@"formatVersion"]=@1;
    for(NSString *key in @[@"probeAccountFileContentsRead",@"storagePermissionsChanged",@"selectionChanged"]){payload[key]=@YES;CHECK(!Payload(payload));payload[key]=@NO;}
    payload[@"other"]=@1;CHECK(!Payload(payload));[payload removeObjectForKey:@"other"];CHECK(Payload(payload));
    char temporary[]="/tmp/socialbox-gate-probe-host.XXXXXX";CHECK(mkdtemp(temporary)!=NULL);NSString *directory=@(temporary),*file=[directory stringByAppendingPathComponent:@"owned-fixture"];
    int fd=open(file.fileSystemRepresentation,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW,0700);CHECK(fd>=0);CHECK(write(fd,"fixture",7)==7);CHECK(fchmod(fd,0755)==0);struct stat node;CHECK(fstat(fd,&node)==0);
    NSMutableDictionary *original=[@{@"device":@(node.st_dev),@"inode":@(node.st_ino),@"owner":@(node.st_uid),@"group":@(node.st_gid),@"flags":@(node.st_flags),@"mode":@0755} mutableCopy];
    NSDictionary *record=@{@"executables":@[@{@"path":file,@"metadata":original}]};NSUInteger changed=0;
    CHECK(Modes(record,NO,&changed)&&changed==1);CHECK(!Modes(record,YES,NULL));CHECK(fchmod(fd,0644)==0);CHECK(Modes(record,YES,&changed)&&changed==1);CHECK(!Modes(record,NO,NULL));
    original[@"inode"]=@(node.st_ino+1);CHECK(!Modes(record,YES,NULL));original[@"inode"]=@(node.st_ino);
    NSString *alias=[directory stringByAppendingPathComponent:@"alias"];CHECK(link(file.fileSystemRepresentation,alias.fileSystemRepresentation)==0);CHECK(!Modes(record,YES,NULL));CHECK(unlink(alias.fileSystemRepresentation)==0);
    CHECK(fchflags(fd,UF_NODUMP)==0);CHECK(!Modes(record,YES,NULL));CHECK(fchflags(fd,0)==0);
    original[@"mode"]=@0644;CHECK(Modes(record,NO,&changed)&&changed==0);CHECK(Modes(record,YES,NULL));
    CHECK([ChildStageName(ChildSetGroups) isEqual:@"setgroups"]);
    CHECK([ChildStageName(ChildGroupPolicy) isEqual:@"group-policy"]);
    CHECK([ChildStageName(999) isEqual:@"invalid-stage"]);
    CHECK([AttemptStageName(AttemptRead) isEqual:@"read-receipt"]);
    CHECK([AttemptStageName(999) isEqual:@"invalid-stage"]);
    SpawnResult blank=EmptySpawnResult();CHECK(blank.spawnError==-1&&blank.groupCount==-1&&blank.foreignGroupCount==-1);
    gid_t primary[]={501},repeated[]={501,501},rootGroup[]={0},foreign[]={20},mixedRoot[]={501,0},mixedForeign[]={501,20};
    CHECK(CredentialValuesAllowed(501,501,501,501,NULL,0));
    CHECK(CredentialValuesAllowed(501,501,501,501,primary,1));
    CHECK(CredentialValuesAllowed(501,501,501,501,repeated,2));
    CHECK(!CredentialValuesAllowed(501,501,501,501,rootGroup,1));
    CHECK(!CredentialValuesAllowed(501,501,501,501,foreign,1));
    CHECK(!CredentialValuesAllowed(501,501,501,501,mixedRoot,2));
    CHECK(!CredentialValuesAllowed(501,501,501,501,mixedForeign,2));
    CHECK(!CredentialValuesAllowed(501,501,501,501,NULL,-1));
    CHECK(!CredentialValuesAllowed(501,501,501,501,NULL,1));
    CHECK(!CredentialValuesAllowed(501,501,501,501,primary,129));
    CHECK(!CredentialValuesAllowed(0,501,501,501,primary,1));
    CHECK(!CredentialValuesAllowed(501,0,501,501,primary,1));
    CHECK(!CredentialValuesAllowed(501,501,0,501,primary,1));
    CHECK(!CredentialValuesAllowed(501,501,501,0,primary,1));
    CHECK(!CredentialValuesAllowed(502,501,501,501,primary,1));
    CHECK(!CredentialValuesAllowed(501,502,501,501,primary,1));
    CHECK(!CredentialValuesAllowed(501,501,502,501,primary,1));
    CHECK(!CredentialValuesAllowed(501,501,501,502,primary,1));
    if(getuid()!=0&&geteuid()!=0){SpawnResult result;SpawnAttempt attempt;
        CHECK(AttemptKind(file,YES,&result,&attempt));CHECK(result.credentialError!=0&&result.spawnError==-1&&!result.unexpectedSpawn);
        CHECK(attempt.stage==AttemptComplete&&result.stage==ChildSetGroups);
        NSDictionary *details=SpawnDetails(&result,&attempt,YES);CHECK([details[@"credentialStage"] isEqual:@"setgroups"]);
        CHECK([details[@"credentialErrno"] intValue]!=0&&[details[@"transportStage"] isEqual:@"complete"]);
        CHECK(AttemptKind(nil,NO,&result,&attempt));CHECK(result.credentialError!=0&&result.spawnError==-1&&!result.unexpectedSpawn);
        CHECK(!AttemptKind(nil,YES,&result,&attempt));CHECK(attempt.stage==AttemptArgument&&attempt.error==EINVAL);
    }
    close(fd);CHECK(unlink(file.fileSystemRepresentation)==0);CHECK(rmdir(temporary)==0);
    puts("PASS probe host protocol, mode readbacks and bounded unprivileged child credential refusal");printf("PASS %u probe assertions; device execution NOT_RUN\n",Checks);return 0;
}}
