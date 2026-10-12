#import "../lucid/HelperSafety/LBXDrainClient.h"
#import <objc/message.h>
static unsigned Checks,Failures,Legacy,Requests;
static BOOL DrainSuccess;
static NSString *RequestedApp;
void LBXRequestApplicationDrain(NSString *app,void (^completion)(BOOL)) {
    Requests++;RequestedApp=[app copy];completion(DrainSuccess);
}
static void Check(BOOL pass,const char *why){Checks++;if(!pass){Failures++;fprintf(stderr,"FAIL %s\n",why);}}
@interface SwitchFixture : NSObject
- (id)helperProxy;
- (void)switchApp:(NSString *)app toContainer:(NSInteger)cid progress:(void (^)(float))progress completion:(void (^)(BOOL,id))completion;
@end
@implementation SwitchFixture
- (id)helperProxy { Legacy++;return @"unmodified original proxy"; }
- (void)switchApp:(NSString *)app toContainer:(NSInteger)cid progress:(void (^)(float))progress completion:(void (^)(BOOL,id))completion {
    (void)app;(void)cid;(void)progress;(void)completion;
}
@end
@interface ChildFixture : SwitchFixture @end
@implementation ChildFixture @end
@interface BadSwitchFixture : NSObject
- (BOOL)helperProxy;
@end
@implementation BadSwitchFixture
- (BOOL)helperProxy{return YES;}
@end
#import "../lucid/HelperSafety/LBXAppSwitchSafety.m"
extern id LBXScopedLookup(id,SEL);
extern char LBXScopeReturn;

// Matches the recovered worker's admission branch: it captures a BOOL but
// branches only on the semaphore wait. Test shortened timeout, real dispatch.
static BOOL Worker(id stop,NSMutableDictionary *metadata,NSInteger target,BOOL *busy,dispatch_semaphore_t lock) {
    Check(dispatch_semaphore_wait(lock,DISPATCH_TIME_NOW)==0,"previous operation released shared lock");
    *busy=YES;
    dispatch_semaphore_t reply=dispatch_semaphore_create(0);
    __block BOOL captured=NO;
    ((void(*)(id,SEL,id,id))objc_msgSend)(stop,NSSelectorFromString(@"killApp:reply:"),@"com.burbn.instagram",^(BOOL success){captured=success;dispatch_semaphore_signal(reply);});
    BOOL signalled=dispatch_semaphore_wait(reply,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC))==0;
    if(signalled)metadata[@"activeContainer"]=@(target);
    *busy=NO;dispatch_semaphore_signal(lock);
    (void)captured;return signalled;
}
@interface LegacyFailure : NSObject
- (void)killApp:(id)app reply:(void (^)(BOOL))reply;
@end
@implementation LegacyFailure
- (void)killApp:(id)app reply:(void (^)(BOOL))reply{(void)app;reply(NO);}
@end
int main(void){@autoreleasepool{
    SwitchFixture *manager=[SwitchFixture new];SEL selector=NSSelectorFromString(@"helperProxy");
    uintptr_t getter=LBXIMPAddress(class_getMethodImplementation(SwitchFixture.class,selector));
    uintptr_t entry=LBXIMPAddress(class_getMethodImplementation(SwitchFixture.class,NSSelectorFromString(@"switchApp:toContainer:progress:completion:")));
    Check(!LBXInstallSwitchSite(BadSwitchFixture.class,getter,entry,(uintptr_t)&LBXScopeReturn),"wrong getter ABI rejected");
    Check(!LBXInstallSwitchSite(ChildFixture.class,getter,entry,(uintptr_t)&LBXScopeReturn),"inherited method rejected");
    Check(!LBXInstallSwitchSite(SwitchFixture.class,getter+4,entry,(uintptr_t)&LBXScopeReturn),"changed getter refused");
    Check(!LBXInstallSwitchSite(SwitchFixture.class,getter,entry+4,(uintptr_t)&LBXScopeReturn),"changed worker entry refused");
    Check(LBXInstallSwitchSite(SwitchFixture.class,getter,entry,(uintptr_t)&LBXScopeReturn),"source guard installed");
    Check([[manager helperProxy] isEqual:@"unmodified original proxy"]&&Legacy==1,"unrelated caller returns original object");
    id stop=LBXScopedLookup(manager,selector);
    Check([stop isKindOfClass:LBXCheckedSwitchStop.class]&&Legacy==1,"actual return PC selects checked stop, never obtains old proxy");
    Check([LBXScopedLookup([ChildFixture new],selector) isEqual:@"unmodified original proxy"]&&Legacy==2,"same caller with subclass stays untouched");
    unsigned before=Requests;[stop killApp:@"com.burbn.instagram" reply:nil];Check(Requests==before,"missing callback has no side effects");
    BOOL busy=NO;dispatch_semaphore_t lock=dispatch_semaphore_create(1);
    NSMutableDictionary *metadata=[@{@"activeContainer":@7,@"marker":@"existing data"} mutableCopy];
    Check(Worker([LegacyFailure new],metadata,8,&busy,lock)&&[metadata[@"activeContainer"] isEqual:@8],"reproduced original defect: false stop still changes metadata");
    metadata[@"activeContainer"]=@7;
    for(unsigned i=0;i<40;i++){
        NSDictionary *snapshot=[metadata copy];DrainSuccess=NO;
        Check(!Worker(stop,metadata,100+i,&busy,lock)&&!busy&&[metadata isEqual:snapshot],"failed verified drain leaves active data unchanged and clears busy");
        DrainSuccess=YES;
        Check(Worker(stop,metadata,100+i,&busy,lock)&&!busy&&[metadata[@"activeContainer"] isEqual:@(100+i)],"verified absent receipt admits exactly requested selection");
    }
    Check([RequestedApp isEqual:@"com.burbn.instagram"]&&Legacy==2,"all protected requests route to source service, never old helper");
    Check(!LBXInstallSwitchSite(SwitchFixture.class,getter,entry,(uintptr_t)&LBXScopeReturn),"second install cannot overwrite original IMP");
    Check(LBXDigestMatches("abc",3,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")&&!LBXDigestMatches("abd",3,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),"host/code digest accepts exact bytes only");
    Check(!LBXPinnedSwitchHost(NSBundle.mainBundle.executablePath),"test/foreign executable never installs production guard");
    printf("%s app switch guard: %u checks, %u failures; synthetic worker, real Objective-C callsite/dispatch\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
