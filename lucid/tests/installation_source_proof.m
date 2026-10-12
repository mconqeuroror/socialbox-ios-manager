// Reuse actual filesystem and synthetic RSA-signed website fixture helpers.
// The original fixture main is compiled but not executed by this focused suite.
#define main InstallationBaselineFixtureMain
#include "installation_establishment.m"
#undef main
#import "../Containers/LBXContainerConfiguration.h"

#if LBX_LICENSE_INSTALLATION_TESTING
static void Admit(LBXLicenseInstallationEstablishment *proof,BOOL first) {
    SignedStatus=@"active";
    [proof.vault testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    [proof.licenseOwner testUseProtocol:PreparedProtocol.class publicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];
    Check([Send(proof.licenseOwner,first?@"activate":@"validate")[@"result"] isEqual:@"active"]&&proof.licenseOwner.sourceAuthorizationCurrent,@"genuine synthetic signed admission for exact prepared owner");
}
static NSDictionary *Ordinary(LBXLicenseInstallationEstablishment *proof,LBXLicenseOwner *owner,LBXContainerConfigurationStore *store,NSString *path,double deadline) {
    return [proof privatePreparedWitnessForLicenseOwner:owner configurationStore:store pendingDirectory:path inCurrentSourceOperationBeforeDeadline:deadline error:nil];
}
static NSDictionary *Initial(LBXLicenseInstallationEstablishment *proof,LBXLicenseOwner *owner,LBXContainerConfigurationStore *store,NSDictionary *context,NSString *path,double deadline) {
    return [proof consumeForInitialPendingWithLicenseOwner:owner configurationStore:store namespaceContext:context pendingDirectory:path inCurrentSourceOperationBeforeDeadline:deadline error:nil];
}
static NSDictionary *Reserve(LBXLicenseInstallationEstablishment *proof,NSString *path,NSDictionary *context,double deadline) {
    return [proof reserveInitialPendingWithLicenseOwner:proof.licenseOwner configurationStore:proof.configurationStore namespaceContext:context
        pendingDirectory:path inCurrentSourceOperationBeforeDeadline:deadline error:nil];
}
static BOOL Overwrite(NSString *path,NSData *data) {
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_NOFOLLOW|O_NONBLOCK);if(fd<0)return NO;
    BOOL result=pwrite(fd,data.bytes,data.length,0)==(ssize_t)data.length&&!ftruncate(fd,(off_t)data.length)&&!fsync(fd);return !close(fd)&&result;
}
static void ImmutableWitness(id value) {
    if([value isKindOfClass:NSDictionary.class]){
        BOOL blocked=NO;@try{[(NSMutableDictionary *)value setObject:@YES forKey:@"unknown"];}@catch(__unused NSException *exception){blocked=YES;}Check(blocked,@"private witness dictionary mutation throws");
        for(id child in [value allValues])ImmutableWitness(child);
    }else if([value isKindOfClass:NSString.class]){
        NSString *before=[value copy];BOOL blocked=NO;@try{[(NSMutableString *)value appendString:@"changed"];}@catch(__unused NSException *exception){blocked=YES;}Check(blocked&&[value isEqual:before],@"private witness string mutation throws without changing facts");
    }
}
static void ScopeTests(NSString *base,NSData *client) {
    NSDictionary *paths=Paths(base,@"source-scope");LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);
    Check(proof!=nil,@"actual pristine prepared scope fixture");LBXLicenseOwner *owner=proof.licenseOwner;LBXContainerConfigurationStore *store=proof.configurationStore;
    NSDictionary *namespace=[store configurationNamespaceContextForTrustedInstaller:nil],*baseline=[proof privatePreparedWitness:nil];double deadline=LBXLicenseIPCClock()+3;
    Check(!Ordinary(proof,owner,store,paths[@"pending"],deadline)&&!Initial(proof,owner,store,namespace,paths[@"pending"],deadline),@"unpaired provenance never substitutes for signed source admission");
    Check(![store verifyHeldEmptyNamespaceContext:namespace inCurrentSourceOperationBeforeDeadline:deadline error:nil],@"unlicensed/outside-fence context cannot authorize initial consumption");Admit(proof,YES);
    LBXLicenseOwner *foreign=[[LBXLicenseOwner alloc] initWithVault:proof.vault];LBXContainerConfigurationStore *peer=[LBXContainerConfigurationStore openDirectory:paths[@"configuration"] licenseOwner:owner create:NO error:nil];
    Check(peer&&foreign,@"distinct genuine owner and same-path store fixture");NSDictionary *before=Snapshot(base);__block NSDictionary *escaped=nil,*witness=nil;__block BOOL callback=NO;deadline=LBXLicenseIPCClock()+3;
    Check([owner performSourceOperation:^BOOL(NSError **error){
        witness=Ordinary(proof,owner,store,paths[@"pending"],deadline);Check([witness isEqual:baseline]&&witness.count==4,@"ordinary guarded witness has stable exact four-key schema");
        Check(!Initial(proof,owner,store,namespace,paths[@"pending"],deadline),@"active admission without held-empty callback cannot consume initial proof");
        Check(!Ordinary(proof,foreign,store,paths[@"pending"],deadline)&&!Ordinary(proof,owner,peer,paths[@"pending"],deadline),@"exact source owner and store instance are required despite matching vault/path");
        Check(!Ordinary(proof,owner,store,[paths[@"pending"] stringByAppendingString:@"-wrong"],deadline)&&!Ordinary(proof,owner,store,paths[@"pending"],deadline+.01),@"wrong pending path or renewed deadline is refused");
        __block BOOL denied=NO;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{denied=Ordinary(proof,owner,store,paths[@"pending"],deadline)==nil;});Check(denied,@"guarded witness cannot escape owning source queue");
        return [store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){
            callback=YES;escaped=context;Check([store verifyHeldEmptyNamespaceContext:context inCurrentSourceOperationBeforeDeadline:deadline error:nil],@"original callback context reuses actual held lock and verified empty namespace");
            Check([Initial(proof,owner,store,context,paths[@"pending"],deadline) isEqual:baseline],@"typed initial proof consumption succeeds in exact live callback without recursive lock");
            NSDictionary *copied=[NSJSONSerialization JSONObjectWithData:Canonical(context) options:0 error:nil];Check(copied!=context&&[copied isEqual:context],@"copied context is value-identical but has independent identity");
            Check(![store verifyHeldEmptyNamespaceContext:copied inCurrentSourceOperationBeforeDeadline:deadline error:nil]&&!Initial(proof,owner,store,copied,paths[@"pending"],deadline),@"parsed copied namespace cannot replay callback provenance");
            Check(!Initial(proof,owner,store,[context mutableCopy],paths[@"pending"],deadline),@"mutable copied namespace cannot replay callback provenance");
            Check(!Initial(proof,foreign,store,context,paths[@"pending"],deadline)&&!Initial(proof,owner,peer,context,paths[@"pending"],deadline),@"held callback cannot lend authority to foreign owner/store");
            Check(!Initial(proof,owner,store,context,[paths[@"pending"] stringByAppendingString:@"-wrong"],deadline)&&!Initial(proof,owner,store,context,paths[@"pending"],deadline+.01),@"initial proof binds fixed pending path and original deadline");
            __block BOOL initialDenied=NO;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{initialDenied=Initial(proof,owner,store,context,paths[@"pending"],deadline)==nil;});Check(initialDenied,@"held callback provenance cannot escape source queue");
            Check(!Ordinary(proof,owner,store,paths[@"pending"],deadline),@"ordinary witness refuses held-empty callback rather than reacquiring its lock");return YES;
        } error:error];
    } beforeDeadline:deadline error:nil]&&callback&&[Snapshot(base) isEqual:before],@"valid scoped proof consumption is bounded and changes no files");ImmutableWitness(witness);
    Check(!Ordinary(proof,owner,store,paths[@"pending"],deadline)&&!Initial(proof,owner,store,escaped,paths[@"pending"],deadline),@"active admission alone after source fence cannot reuse private witness authority");
    deadline=LBXLicenseIPCClock()+3;Check([owner performSourceOperation:^BOOL(NSError **error){
        Check(!Initial(proof,owner,store,escaped,paths[@"pending"],deadline),@"escaped old callback is denied in a later owner fence");
        return [store performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){
            Check(context!=escaped&&[context isEqual:escaped],@"new callback observes same namespace through a fresh borrowed context");
            Check(!Initial(proof,owner,store,escaped,paths[@"pending"],deadline)&&[Initial(proof,owner,store,context,paths[@"pending"],deadline) isEqual:baseline],@"old callback identity cannot replace actual current callback identity");return YES;
        } error:error];
    } beforeDeadline:deadline error:nil],@"fresh initial consumption remains available after refused replays");
    Check([Send(owner,@"validate")[@"result"] isEqual:@"active"],@"genuine signed validation advances mutable vault state");deadline=LBXLicenseIPCClock()+3;
    Check([owner performSourceOperation:^BOOL(__unused NSError **error){return [Ordinary(proof,owner,store,paths[@"pending"],deadline) isEqual:baseline];} beforeDeadline:deadline error:nil],@"guarded immutable preparation witness remains stable across genuine validation");
    LBXContainerConfiguration *record=[LBXContainerConfiguration createWithName:@"Ordinary saved metadata fixture" applications:@[@"com.burbn.instagram"] manualIdentifiers:nil proxyReference:@"" error:nil];
    Check([store commitConfiguration:record replacing:nil beforeDeadline:LBXLicenseIPCClock()+3 error:nil],@"genuine licensed ordinary metadata record exists for exact-proof scope");
    deadline=LBXLicenseIPCClock()+3;Check([owner performSourceOperation:^BOOL(NSError **error){
        return [store performWithExactConfiguration:record inCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){
            Check([Ordinary(proof,owner,store,paths[@"pending"],deadline) isEqual:baseline],@"ordinary witness reuses existing exact-record proof lock and same deadline");
            Check(!Initial(proof,owner,store,context,paths[@"pending"],deadline)&&![store verifyHeldEmptyNamespaceContext:context inCurrentSourceOperationBeforeDeadline:deadline error:nil],@"exact-record proof callback is not pristine empty setup authority");return YES;
        } error:error];
    } beforeDeadline:deadline error:nil],@"normal established witness has no recursive proof-lock acquisition");
    SignedStatus=@"revoked";Check([Send(owner,@"validate")[@"result"] isEqual:@"revoked"],@"real synthetic signed revocation closes source admission");deadline=LBXLicenseIPCClock()+3;
    Check([proof preparedInstallationCurrent:nil]&&!Ordinary(proof,owner,store,paths[@"pending"],deadline)&&!Initial(proof,owner,store,escaped,paths[@"pending"],deadline),@"descriptive provenance remains current but cannot override signed denial");
}
static void ExpiryTests(NSString *base,NSData *client) {
    for(NSString *kind in @[@"ordinary",@"initial"]){NSDictionary *paths=Paths(base,[@"expiry-" stringByAppendingString:kind]);LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual prepared expiry fixture");Admit(proof,YES);NSDictionary *before=Snapshot(base);double deadline=LBXLicenseIPCClock()+.04;__block BOOL ran=NO,denied=NO;
        [LBXLicenseInstallationEstablishment testBoundaryHandler:^(NSString *boundary){if(!ran&&[boundary isEqual:@"before_final_reobservation"]){ran=YES;usleep(70000);}}];
        BOOL result=[proof.licenseOwner performSourceOperation:^BOOL(NSError **error){
            if([kind isEqual:@"ordinary"]){denied=Ordinary(proof,proof.licenseOwner,proof.configurationStore,paths[@"pending"],deadline)==nil;return YES;}
            return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){denied=Initial(proof,proof.licenseOwner,proof.configurationStore,context,paths[@"pending"],deadline)==nil;return YES;} error:error];
        } beforeDeadline:deadline error:nil];[LBXLicenseInstallationEstablishment testBoundaryHandler:nil];
        Check(ran&&denied&&!result&&[Snapshot(base) isEqual:before],@"expiry during final observation never returns guarded witness or renews original deadline");
    }
}
static void ReplacementTests(NSString *base,NSData *client) {
    for(NSString *mode in @[@"ordinary",@"initial"])for(NSString *leaf in @[@"intent.json",@"prepared.json"]){
        NSDictionary *paths=Paths(base,[NSString stringWithFormat:@"guard-%@-%@",mode,[leaf stringByReplacingOccurrencesOfString:@"." withString:@"-"]]);LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual prepared source replacement fixture");Admit(proof,YES);__block BOOL ran=NO,denied=NO;NSString *target=Join(paths[@"anchor"],leaf),*held=Join(base,[NSString stringWithFormat:@"held-%@-%@",mode,leaf]);
        [LBXLicenseInstallationEstablishment testBoundaryHandler:^(NSString *boundary){if(!ran&&[boundary isEqual:@"before_final_reobservation"]){ran=YES;NSData *bytes=[NSData dataWithContentsOfFile:target];Check(!rename(target.fileSystemRepresentation,held.fileSystemRepresentation)&&Put(target,bytes,0600),@"same-byte source proof replacement retains original inode");}}];
        double deadline=LBXLicenseIPCClock()+3;BOOL result=[proof.licenseOwner performSourceOperation:^BOOL(NSError **error){
            if([mode isEqual:@"ordinary"]){denied=Ordinary(proof,proof.licenseOwner,proof.configurationStore,paths[@"pending"],deadline)==nil;return YES;}
            return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){denied=Initial(proof,proof.licenseOwner,proof.configurationStore,context,paths[@"pending"],deadline)==nil;return YES;} error:error];
        } beforeDeadline:deadline error:nil];[LBXLicenseInstallationEstablishment testBoundaryHandler:nil];
        Check(result&&ran&&denied&&!Open(paths,client),@"same-byte anchor changes deny guarded witness during callback and after reopening");NSDictionary *changed=Snapshot(base);deadline=LBXLicenseIPCClock()+3;
        Check([proof.licenseOwner performSourceOperation:^BOOL(__unused NSError **error){Check(!Ordinary(proof,proof.licenseOwner,proof.configurationStore,paths[@"pending"],deadline),@"repeated source proof observation cannot adopt replacement");return YES;} beforeDeadline:deadline error:nil]&&[Snapshot(base) isEqual:changed],@"repeated replacement denials preserve all current and held nodes");
    }
    NSDictionary *paths=Paths(base,@"initial-lock-changed");LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual prepared held-lock replacement fixture");Admit(proof,YES);__block BOOL denied=NO;NSString *lock=Join(paths[@"configuration"],@"configuration.lock"),*held=Join(base,@"held-config-lock");double deadline=LBXLicenseIPCClock()+3;
    Check(![proof.licenseOwner performSourceOperation:^BOOL(NSError **error){return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){
        Check(!rename(lock.fileSystemRepresentation,held.fileSystemRepresentation)&&Put(lock,NSData.data,0600),@"held configuration lock is actually replaced");denied=Initial(proof,proof.licenseOwner,proof.configurationStore,context,paths[@"pending"],deadline)==nil;return YES;
    } error:error];} beforeDeadline:deadline error:nil]&&denied&&Snapshot(lock)&&Snapshot(held),@"initial verifier denies actual lock replacement without repair or deletion");
    paths=Paths(base,@"initial-unknown-node");proof=Prepare(paths,client);Check(proof!=nil,@"actual prepared unknown-inventory fixture");Admit(proof,YES);NSString *unknown=Join(paths[@"configuration"],@"unknown.json");deadline=LBXLicenseIPCClock()+3;denied=NO;
    Check(![proof.licenseOwner performSourceOperation:^BOOL(NSError **error){return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){
        Check([Initial(proof,proof.licenseOwner,proof.configurationStore,context,paths[@"pending"],deadline) count]==4,@"original empty inventory is verified before external fixture mutation");
        Check(Put(unknown,[@"unknown" dataUsingEncoding:NSUTF8StringEncoding],0600),@"unexpected actual node appears while configuration lock is held");
        denied=![proof.configurationStore verifyHeldEmptyNamespaceContext:context inCurrentSourceOperationBeforeDeadline:deadline error:nil]&&!Initial(proof,proof.licenseOwner,proof.configurationStore,context,paths[@"pending"],deadline);return YES;
    } error:error];} beforeDeadline:deadline error:nil]&&denied&&[[NSData dataWithContentsOfFile:unknown] isEqual:[@"unknown" dataUsingEncoding:NSUTF8StringEncoding]],@"held proof consumer and callback reject unknown inventory while preserving its bytes");
}
static void OneShotTests(NSString *base,NSData *client) {
    NSDictionary *paths=Paths(base,@"one-shot");LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual one-shot prepared fixture");
    NSString *seed=Join(paths[@"anchor"],@"pending-establishment.json");NSData *pristine=[NSData dataWithContentsOfFile:seed];NSDictionary *node=Snapshot(seed),*witness=[proof privatePreparedWitness:nil];
    NSDictionary *prepared=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Join(paths[@"anchor"],@"prepared.json")] options:0 error:nil];
    Check([prepared[@"pendingEstablishment"] count]==3&&[prepared[@"pendingEstablishment"][@"pristineFile"] count]==11&&
        [prepared[@"pendingEstablishment"][@"pristineSHA256"] isEqual:SHA(pristine)],@"immutable prepared record binds exact pristine full file witness and canonical digest");
    double deadline=LBXLicenseIPCClock()+3;NSDictionary *before=Snapshot(base);
    Check(!Reserve(proof,paths[@"pending"],@{},deadline)&&[Snapshot(base) isEqual:before],@"unlicensed outside-callback reservation has no effects");Admit(proof,YES);
    LBXContainerConfigurationStore *peer=[LBXContainerConfigurationStore openDirectory:paths[@"configuration"] licenseOwner:proof.licenseOwner create:NO error:nil];
    __block BOOL reserved=NO;deadline=LBXLicenseIPCClock()+3;
    Check([proof.licenseOwner performSourceOperation:^BOOL(NSError **error){return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){
        NSDictionary *copy=[NSJSONSerialization JSONObjectWithData:Canonical(context) options:0 error:nil];
        Check(!Reserve(proof,paths[@"pending"],copy,deadline)&&!Reserve(proof,paths[@"pending"],context,deadline+.01)&&!Reserve(proof,[paths[@"pending"] stringByAppendingString:@"-wrong"],context,deadline),@"reservation rejects copied context, wrong deadline and path before writes");
        Check(![proof reserveInitialPendingWithLicenseOwner:proof.licenseOwner configurationStore:peer namespaceContext:context pendingDirectory:paths[@"pending"] inCurrentSourceOperationBeforeDeadline:deadline error:nil],@"reservation cannot borrow another store instance");
        __block BOOL denied=NO;dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{denied=!Reserve(proof,paths[@"pending"],context,deadline);});Check(denied,@"reservation cannot escape the exact source queue");
        Check([Snapshot(seed) isEqual:node],@"refused reserve inputs preserve exact pristine node and bytes");
        reserved=[Reserve(proof,paths[@"pending"],context,deadline) isEqual:witness];Check(reserved,@"exact pristine seed reserves once with unchanged immutable preparation witness");
        NSDictionary *terminal=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:seed] options:0 error:nil];
        Check(terminal.count==5&&[terminal[@"phase"] isEqual:@"consumed"]&&[Snapshot(seed)[@"inode"] isEqual:node[@"inode"]],@"terminal fixed five-key record remains on the original inode");
        Check([Initial(proof,proof.licenseOwner,proof.configurationStore,context,paths[@"pending"],deadline) isEqual:witness]&&!Reserve(proof,paths[@"pending"],context,deadline),@"terminal permits final observation but never a second reservation");return YES;
    } error:error];} beforeDeadline:deadline error:nil]&&reserved&&!Snapshot(paths[@"pending"]),@"one-shot source reservation never initializes pending storage itself");
    LBXLicenseInstallationEstablishment *reopened=Open(paths,client);Check(reopened&&[[reopened privatePreparedWitness:nil] isEqual:witness],@"reopened consumed record observes the same stable preparation proof");Admit(reopened,NO);deadline=LBXLicenseIPCClock()+3;before=Snapshot(base);
    Check([reopened.licenseOwner performSourceOperation:^BOOL(NSError **error){return [reopened.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){Check(!Reserve(reopened,paths[@"pending"],context,deadline),@"restart does not turn terminal consumption into fresh setup");return YES;} error:error];} beforeDeadline:deadline error:nil]&&[Snapshot(base) isEqual:before],@"refused restarted reservation preserves consumed evidence");
    Check(Overwrite(seed,pristine)&&[Snapshot(seed)[@"inode"] isEqual:node[@"inode"]],@"stale pristine bytes are physically restored on the same original inode");before=Snapshot(base);
    Check(![proof preparedInstallationCurrent:nil]&&![reopened preparedInstallationCurrent:nil]&&!Open(paths,client)&&[Snapshot(base) isEqual:before],@"immutable initial full witness rejects stale pristine restoration cached and after reopen without repair");
}
static void ReserveFailureTests(NSString *base,NSData *client) {
    for(NSString *boundary in @[@"before_pending_reserve",@"pending_reserve_written",@"pending_reserve_truncated",@"pending_reserve_synced"]){
        NSDictionary *paths=Paths(base,[@"reserve-stop-" stringByAppendingString:boundary]);LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual interrupted-reservation fixture");Admit(proof,YES);NSString *seed=Join(paths[@"anchor"],@"pending-establishment.json");NSDictionary *before=Snapshot(seed);__block BOOL denied=NO;
        [LBXLicenseInstallationEstablishment testStopAfterBoundary:boundary];double deadline=LBXLicenseIPCClock()+3;
        Check(![proof.licenseOwner performSourceOperation:^BOOL(NSError **error){return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){denied=!Reserve(proof,paths[@"pending"],context,deadline);return !denied;} error:error];} beforeDeadline:deadline error:nil]&&denied,@"failure-only reservation boundary never returns success");[LBXLicenseInstallationEstablishment testStopAfterBoundary:nil];
        NSDictionary *record=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:seed] options:0 error:nil];BOOL untouched=[boundary isEqual:@"before_pending_reserve"];
        Check([record[@"phase"] isEqual:untouched?@"pristine":@"consumed"]&&[Snapshot(seed)[@"inode"] isEqual:before[@"inode"]]&&!Snapshot(paths[@"pending"]),@"interrupted reservation retains original inode and observable phase without pending effects");
        LBXLicenseInstallationEstablishment *reopened=Open(paths,client);Check(reopened!=nil,@"complete observed seed bytes may reopen after uncertain return without claiming power-loss durability");Admit(reopened,NO);deadline=LBXLicenseIPCClock()+3;
        Check([reopened.licenseOwner performSourceOperation:^BOOL(NSError **error){return [reopened.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){Check((Reserve(reopened,paths[@"pending"],context,deadline)!=nil)==untouched,@"only refusal before the first effect can leave a reservable pristine seed");return YES;} error:error];} beforeDeadline:deadline error:nil],@"interrupted terminal evidence is never reconstructed or reset");
    }
    for(NSString *kind in @[@"expiry-before",@"expiry-after",@"partial",@"replaced"]){
        NSDictionary *paths=Paths(base,[@"reserve-change-" stringByAppendingString:kind]);LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual in-flight reservation counterexample");Admit(proof,YES);NSString *seed=Join(paths[@"anchor"],@"pending-establishment.json");NSDictionary *before=Snapshot(seed);__block BOOL ran=NO,denied=NO;double deadline=LBXLicenseIPCClock()+([kind hasPrefix:@"expiry"]?.05:3);
        [LBXLicenseInstallationEstablishment testBoundaryHandler:^(NSString *boundary){BOOL early=[kind isEqual:@"expiry-before"]||[kind isEqual:@"replaced"];if(!ran&&[boundary isEqual:early?@"before_pending_reserve":@"pending_reserve_written"]){ran=YES;
            if([kind hasPrefix:@"expiry"])usleep(80000);
            else if([kind isEqual:@"partial"])Check(Overwrite(seed,[@"{" dataUsingEncoding:NSUTF8StringEncoding]),@"actual same-inode partial record appears after known reservation write");
            else Check(!rename(seed.fileSystemRepresentation,Join(base,@"held-reserve-seed").fileSystemRepresentation)&&Put(seed,before[@"bytes"],0600),@"actual seed path replacement occurs before first reservation write");
        }}];
        Check(![proof.licenseOwner performSourceOperation:^BOOL(NSError **error){return [proof.configurationStore performWithVerifiedEmptyNamespaceInCurrentSourceOperationBeforeDeadline:deadline operation:^BOOL(NSDictionary *context,__unused NSError **failure){denied=!Reserve(proof,paths[@"pending"],context,deadline);return !denied;} error:error];} beforeDeadline:deadline error:nil]&&ran&&denied,@"deadline or physical substitution during reservation never returns a witness");[LBXLicenseInstallationEstablishment testBoundaryHandler:nil];
        if([kind isEqual:@"partial"]){Check([[NSData dataWithContentsOfFile:seed] isEqual:[@"{" dataUsingEncoding:NSUTF8StringEncoding]],@"detected partial state is preserved without later truncate/repair");Check(![proof preparedInstallationCurrent:nil]&&!Open(paths,client),@"partial seed is closed cached and after reopen");}
        else if([kind isEqual:@"replaced"])Check([Snapshot(seed)[@"bytes"] isEqual:before[@"bytes"]]&&![proof preparedInstallationCurrent:nil]&&!Open(paths,client),@"substituted pristine bytes are untouched and never adopted");
        else{NSDictionary *record=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:seed] options:0 error:nil];Check([record[@"phase"] isEqual:[kind isEqual:@"expiry-before"]?@"pristine":@"consumed"],@"original deadline failure retains the exact observed pre/post effect phase");}
    }
}
static void SeedIntegrityTests(NSString *base,NSData *client) {
    for(NSString *kind in @[@"missing",@"public",@"acl",@"hardlink",@"malformed",@"boolean",@"unknown-phase",@"extra"]){NSDictionary *paths=Paths(base,[@"seed-" stringByAppendingString:kind]);LBXLicenseInstallationEstablishment *proof=Prepare(paths,client);Check(proof!=nil,@"actual seed-integrity prepared fixture");NSString *seed=Join(paths[@"anchor"],@"pending-establishment.json");
        if([kind isEqual:@"missing"])Check(!rename(seed.fileSystemRepresentation,Join(base,@"held-missing-seed").fileSystemRepresentation),@"seed disappears without destroying original node");
        else if([kind isEqual:@"public"])Check(!chmod(seed.fileSystemRepresentation,0644),@"seed mode becomes public");
        else if([kind isEqual:@"acl"])Check(ACL(seed,YES),@"seed gains actual ACL");
        else if([kind isEqual:@"hardlink"])Check(!link(seed.fileSystemRepresentation,Join(base,@"linked-seed").fileSystemRepresentation),@"seed gains actual extra link");
        else if([kind isEqual:@"malformed"])Check(Overwrite(seed,[@"{" dataUsingEncoding:NSUTF8StringEncoding]),@"seed contains partial canonical record");
        else{NSMutableDictionary *record=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:seed] options:0 error:nil] mutableCopy];if([kind isEqual:@"boolean"])record[@"formatVersion"]=@YES;else if([kind isEqual:@"unknown-phase"])record[@"phase"]=@"ready";else record[@"unknown"]=@1;Check(Overwrite(seed,Canonical(record)),@"seed malformed exact-shape fixture");}
        NSDictionary *before=Snapshot(base);Check(![proof preparedInstallationCurrent:nil]&&!Open(paths,client)&&[Snapshot(base) isEqual:before],@"missing/unsafe/noncanonical seed refuses cached and reopened provenance without repair");
    }
}
int main(void){@autoreleasepool{
    char temporary[]="/private/tmp/socialbox-prepared-source.XXXXXX";Check(mkdtemp(temporary)!=NULL,@"actual temporary parent for source proof tests");NSString *base=[NSString stringWithUTF8String:temporary];Check(!chown(base.fileSystemRepresentation,geteuid(),getegid()),@"fixture parent explicit owner/group");
    NSData *client=[@"#!/fixture-client\n" dataUsingEncoding:NSUTF8StringEncoding];for(NSString *key in @[@"installer",@"service",@"client"])Check(Put(Join(base,key),[[NSString stringWithFormat:@"#!/fixture-%@\n",key] dataUsingEncoding:NSUTF8StringEncoding],0755),@"fixed executable file fixture");
    ScopeTests(base,client);ExpiryTests(base,client);ReplacementTests(base,client);OneShotTests(base,client);ReserveFailureTests(base,client);SeedIntegrityTests(base,client);[LBXLicenseInstallationEstablishment testBoundaryHandler:nil];
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];printf("%s: %lu source prepared-proof assertions, %lu failures (actual filesystem; synthetic signed admission)\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
}}
#else
int main(void){return InstallationBaselineFixtureMain();}
#endif
