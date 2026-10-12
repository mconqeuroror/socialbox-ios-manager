// Dedicated synthetic ABI/provenance/action fixture. It never loads the recovered
// runtime, contacts a service, or changes a real container or license.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "SBBackendAdapter.h"

static NSUInteger Checks, Dispatches, GetterReads;
static NSMutableArray<NSString *> *Failures;
static id LastSender, LastContainer;
static void Check(BOOL pass, NSString *name) { Checks++; if (!pass) [Failures addObject:name]; }
static NSDictionary *Metadata(void) { return @{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"}; }

@interface AdapterHost : UIViewController
@property(nonatomic,strong) UILabel *valueLabel;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UISwitch *toggle;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) CAGradientLayer *meshGradientLayer;
@end
@implementation AdapterHost
- (void)viewDidLoad {
    [super viewDidLoad]; self.valueLabel=[UILabel new]; self.valueLabel.text=@"Synthetic value"; [self.view addSubview:self.valueLabel];
    self.button=[UIButton buttonWithType:UIButtonTypeSystem]; [self.view addSubview:self.button];
    [self.button addTarget:self action:@selector(receive:) forControlEvents:UIControlEventTouchUpInside];
    self.toggle=[UISwitch new]; [self.view addSubview:self.toggle];
    [self.toggle addTarget:self action:@selector(receive:) forControlEvents:UIControlEventValueChanged];
    self.contentStack=[UIStackView new]; [self.view addSubview:self.contentStack];
    self.meshGradientLayer=[CAGradientLayer new]; [self.view.layer addSublayer:self.meshGradientLayer];
}
- (void)receive:(id)sender { Dispatches++; LastSender=sender; }
@end
@interface HomeViewController:AdapterHost @end
@implementation HomeViewController
- (UILabel *)modelNameValue { GetterReads++; return self.valueLabel; }
- (UIButton *)fingerprintButton { return self.button; }
- (UISwitch *)mainToggle { return self.toggle; }
- (void)openConfigureSpoofing { Dispatches++; }
@end
@interface UnknownHome:HomeViewController @end
@implementation UnknownHome @end
@interface SettingsViewController:AdapterHost @end
@implementation SettingsViewController
- (BOOL)copySeed { Dispatches++; return YES; } // Deliberately incompatible ABI.
@end
#define SCREEN(NAME) @interface NAME:AdapterHost @end @implementation NAME @end
SCREEN(LocSimViewController)
SCREEN(ProxyViewController)
SCREEN(FakeInfoViewController)
SCREEN(_Xm8u)
SCREEN(_Xd2z)
SCREEN(SocialBoxOnboardingViewController)
SCREEN(CountryPickerViewController)
SCREEN(CarrierPickerViewController)
SCREEN(VersionPickerViewController)
SCREEN(DRTAllowedModelsViewController)
SCREEN(AppListViewController)
SCREEN(BackupsViewController)
SCREEN(CloudViewController)
SCREEN(CloudPushViewController)
SCREEN(TokensDetailViewController)
SCREEN(BulkProxyImportViewController)
SCREEN(UserGuideViewController)
SCREEN(AddonsMarketViewController)
SCREEN(CryptoCheckoutViewController)
SCREEN(CloudPlansViewController)
@interface SessionHost:AdapterHost
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UITextField *labelField;
@property(nonatomic,strong) UITextField *passphraseField;
@property(nonatomic,strong) UISearchBar *searchBar;
- (UITableView *)tableView;
@end
@implementation SessionHost
- (void)viewDidLoad {
    [super viewDidLoad];self.table=[UITableView new];self.spinner=[UIActivityIndicatorView new];
    self.labelField=[UITextField new];self.passphraseField=[UITextField new];self.searchBar=[UISearchBar new];
    for(UIView *view in @[self.table,self.spinner,self.labelField,self.passphraseField,self.searchBar])[self.view addSubview:view];
}
- (UITableView *)tableView{return self.table;}
@end
#define SESSION_SCREEN(NAME) @interface NAME:SessionHost @end @implementation NAME @end
SESSION_SCREEN(TokensViewController)
SESSION_SCREEN(TokensImportViewController)
SESSION_SCREEN(CMVC_BulkCloudPushViewController)
SESSION_SCREEN(TokensBulkExtractViewController)
SESSION_SCREEN(TokensRouteAllPickerViewController)
static id UnreviewedTable(id owner,SEL selector){(void)owner;(void)selector;GetterReads++;return nil;}
@interface ModelPickerViewController:UITableViewController @end
@implementation ModelPickerViewController @end

@interface _Xv8i:NSObject
@property(nonatomic) long long containerID;
@property(nonatomic,strong) NSString *name;
@property(nonatomic,strong) NSArray *apps;
@property(nonatomic,strong) NSString *proxyTitle;
@property(nonatomic,strong) NSString *spoofProfileID;
@end
@implementation _Xv8i @end
@interface _Xc9m:AdapterHost
@property(nonatomic,strong) NSArray *rows;
@property(nonatomic) long long selectedID;
@property(nonatomic) BOOL changeSelection;
@property(nonatomic) NSUInteger selectedReads;
@property(nonatomic) NSUInteger listReads;
@property(nonatomic) NSUInteger disappearAfterRead;
@end
@implementation _Xc9m
- (NSArray *)containers {
    self.listReads++;
    return self.disappearAfterRead && self.listReads>=self.disappearAfterRead ? @[] : self.rows;
}
- (long long)activeContainerID { self.selectedReads++; return self.selectedID+(self.changeSelection ? self.selectedReads : 0); }
- (NSString *)folderNameForContainerID:(long long)identifier { return identifier==41 ? @"Research" : nil; }
- (id)containerInfoAtIndexPath:(NSIndexPath *)index { return index.row==0 ? self.rows.lastObject : nil; }
- (void)renameContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)confirmDeleteContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)confirmSwitchToContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)editAppsForContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)showProxyPickerForContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)exportContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)createFolderAndMoveContainer:(id)row { Dispatches++; LastContainer=row; }
- (void)removeContainerFromFolder:(id)row { Dispatches++; LastContainer=row; }
- (void)importContainerTapped { Dispatches++; }
- (void)confirmSwitchToDefault { Dispatches++; }
@end
static _Xv8i *Row(long long identifier, NSString *name, NSArray *apps) {
    _Xv8i *row=[_Xv8i new]; row.containerID=identifier; row.name=name; row.apps=apps; return row;
}
static void RunTests(void) {
    Failures=[NSMutableArray array]; NSString *reason=nil;
    SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    Check(SBBackendMetadataSupported(Metadata(),&reason) && !reason,@"pinned metadata");
    for (NSString *key in Metadata()) {
        NSMutableDictionary *bad=[Metadata() mutableCopy]; bad[key]=@"wrong";
        Check(!SBBackendMetadataSupported(bad,&reason) && reason.length,@"metadata mismatch refused");
    }
    Check(SBBackendScreenRegistry().count==29,@"exact screen registry including one denied store alias");
    Check(SBBackendCompatibilityScreensDictionary().count==26,@"only presentation screens installed");
    Check(!SBBackendCompatibilityScreensDictionary()[SBBackendSupportedClassName(SBScreenMarket)],@"market excluded from presentation");
    Check(!SBBackendCompatibilityScreensDictionary()[SBBackendSupportedClassName(SBScreenCheckout)],@"checkout excluded from presentation");
    Check(SBBackendScreen([CloudPlansViewController new])==SBScreenMarket&&!SBBackendCompatibilityScreensDictionary()[@"CloudPlansViewController"],@"exact cloud-plans store alias denied without classifying licensed cloud as store");
    Check(SBBackendScreen([CloudViewController new])==SBScreenCloud&&SBBackendCompatibilityScreensDictionary()[@"CloudViewController"]!=nil,@"licensed cloud route remains admitted");
    for (NSDictionary *spec in SBBackendScreenRegistry()) {
        id owner=[[NSClassFromString(spec[@"className"]) alloc] init];
        Check(SBBackendScreen(owner)==[spec[@"screen"] integerValue],@"exact role classification");
    }
    for(Class cls in @[TokensViewController.class,TokensImportViewController.class,CMVC_BulkCloudPushViewController.class,TokensBulkExtractViewController.class,TokensRouteAllPickerViewController.class]) {
        SessionHost *session=[cls new];NSUInteger before=Dispatches;
        Check(!SBBackendReadObject(session,@"surface",nil)&&!session.isViewLoaded,@"session getters never load original UI");
        [session loadViewIfNeeded];
        Check(SBBackendReadObject(session,@"surface",nil)==session.table&&Dispatches==before,@"reviewed session or bulk-cloud table getter is read-only");
        Check(!SBBackendReadObject(session,@"bagPassword",nil)&&!SBBackendReadObject(session,@"savedPassphrase",nil)&&!SBBackendInvoke(session,@"_inject",nil,nil)&&!SBBackendInvoke(session,@"confirmTapped",nil,nil),@"secret model getters and worker dispatch are not exposed");
        if(cls==TokensViewController.class)Check(SBBackendReadObject(session,@"activity",nil)==session.spinner,@"reviewed sessions spinner identity");
        if(cls==TokensRouteAllPickerViewController.class){
            Check(SBBackendReadObject(session,@"search",nil)==session.searchBar&&!SBBackendReadObject(session,@"completion",nil)&&!SBBackendReadObject(session,@"allContainers",nil),@"destination reads exact search control without exposing completion or models");
            [session.searchBar removeFromSuperview];Check(!SBBackendReadObject(session,@"search",nil),@"detached destination search is rejected");
        }
        if(cls==CMVC_BulkCloudPushViewController.class){
            Check(SBBackendReadObject(session,@"label",nil)==session.labelField&&SBBackendReadObject(session,@"passphrase",nil)==session.passphraseField,@"bulk-cloud exact native fields");
            [session.passphraseField removeFromSuperview];Check(!SBBackendReadObject(session,@"passphrase",nil),@"detached bulk-cloud field is rejected");
        }
    }
    TokensImportViewController *badSession=[TokensImportViewController new];[badSession loadViewIfNeeded];
    NSUInteger beforeBadGetter=GetterReads;
    class_addMethod(TokensImportViewController.class,@selector(table),(IMP)UnreviewedTable,"@24@0:8");
    Check(!SBBackendReadObject(badSession,@"surface",nil)&&GetterReads==beforeBadGetter,@"exact session getter ABI rejects altered encoding before invocation");
    HomeViewController *home=[HomeViewController new];
    Check(!SBBackendReadObject(home,@"identity.modelName",&reason) && !home.isViewLoaded,@"reads do not load view");
    [home loadViewIfNeeded];
    Check(SBBackendReadObject(home,@"identity.modelName",&reason)==home.valueLabel && !reason,@"guarded label read");
    Check(SBBackendReadObject(home,@"surface",nil)==home.contentStack,@"neutral surface read");
    Check(SBBackendReadObject(home,@"mesh",nil)==home.meshGradientLayer,@"neutral layer read");
    Check(SBBackendScreen([UnknownHome new])==SBScreenUnknown,@"unregistered subclass refused");
    Check(!SBBackendReadObject(home,@"containers",&reason),@"model getters not arbitrary presentation API");
    NSUInteger reads=GetterReads;
    SBBackendFixtureConfigure(@{},NSBundle.mainBundle.executablePath);
    Check(!SBBackendReadObject(home,@"identity.modelName",&reason) && GetterReads==reads,@"wrong metadata rejects before getter");
    SBBackendFixtureConfigure(Metadata(),@"/not/the/host");
    Check(!SBBackendReadObject(home,@"identity.modelName",&reason) && GetterReads==reads,@"wrong class image rejects before getter");
    SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    [home.valueLabel removeFromSuperview];
    Check(!SBBackendReadObject(home,@"identity.modelName",&reason),@"foreign presentation ownership refused");
    [home.view addSubview:home.valueLabel];
    [home.meshGradientLayer removeFromSuperlayer];
    Check(!SBBackendReadObject(home,@"mesh",&reason),@"detached layer refused");
    [home.view.layer addSublayer:home.meshGradientLayer];
    Method method=class_getInstanceMethod(HomeViewController.class,@selector(modelNameValue));
    IMP original=method_getImplementation(method), external=class_getMethodImplementation(UIViewController.class,@selector(title));
    method_setImplementation(method,external);
    Check(!SBBackendReadObject(home,@"identity.modelName",&reason),@"foreign implementation image refused");
    method_setImplementation(method,original);
    ModelPickerViewController *picker=[ModelPickerViewController new]; [picker loadViewIfNeeded];
    Check(SBBackendReadObject(picker,@"surface",&reason)==picker.tableView,@"reviewed inherited UIKit table allowed");
    Check(SBBackendActionAvailable(home,@"home.configureIdentity",nil,&reason) && Dispatches==0,@"availability is read only");
    Check(SBBackendInvoke(home,@"home.configureIdentity",nil,&reason) && Dispatches==1,@"reviewed noarg action");
    Check(!SBBackendInvoke(home,@"openConfigureSpoofing",nil,&reason),@"arbitrary selector action refused");
    Check(!SBBackendInvoke(home,@"home.configureIdentity",home.button,&reason),@"unexpected noarg sender refused");
    SettingsViewController *settings=[SettingsViewController new]; [settings loadViewIfNeeded];
    NSUInteger dispatches=Dispatches;
    Check(!SBBackendInvoke(settings,@"settings.copySeed",nil,&reason) && Dispatches==dispatches,@"wrong action return ABI refused");
    Check(!SBBackendInvoke(settings,@"home.configureIdentity",nil,&reason),@"cross-screen action refused");
    Check(!SBBackendSendControl(home,@"identity.create",UIControlEventValueChanged,&reason),@"wrong control event refused");
    Check(SBBackendSendControl(home,@"identity.create",UIControlEventTouchUpInside,&reason) && LastSender==home.button,@"original sender preserved");
    Check(SBBackendInvoke(home,@"home.create",home.button,&reason),@"explicit native sender accepted");
    Check(!SBBackendInvoke(home,@"home.create",[UIButton new],&reason),@"replacement sender refused");
    home.button.enabled=NO; dispatches=Dispatches;
    Check(!SBBackendSendControl(home,@"identity.create",UIControlEventTouchUpInside,&reason) && Dispatches==dispatches,@"disabled native action preserved");
    home.button.enabled=YES; home.button.hidden=YES;
    Check(!SBBackendSendControl(home,@"identity.create",UIControlEventTouchUpInside,&reason),@"hidden native action preserved");
    home.button.hidden=NO; UIView *newSurface=[UIView new]; [home.view addSubview:newSurface]; [newSurface addSubview:home.button];
    Check(SBBackendSendControl(home,@"identity.create",UIControlEventTouchUpInside,&reason) && LastSender==home.button,@"moved owned sender preserved");
    Check(SBBackendSendControl(home,@"identity.toggle",UIControlEventValueChanged,&reason) && LastSender==home.toggle,@"native switch event preserved");
    __block BOOL offThread=NO;
    dispatch_semaphore_t completed=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ offThread=SBBackendReadObject(home,@"identity.modelName",nil)==nil && !SBBackendInvoke(home,@"home.configureIdentity",nil,nil); dispatch_semaphore_signal(completed); });
    dispatch_semaphore_wait(completed,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
    Check(offThread,@"off-main reads and actions denied");

    _Xc9m *containers=[_Xc9m new]; [containers loadViewIfNeeded];
    NSMutableString *mutableName=[@"Same label" mutableCopy];
    _Xv8i *a=Row(41,mutableName,@[@"com.reddit.Reddit"]), *b=Row(9001,@"Same label",@[@"com.facebook.Facebook"]);
    a.proxyTitle=@"North"; a.spoofProfileID=@"saved-profile"; containers.rows=@[a,b]; containers.selectedID=9001;
    dispatches=Dispatches; SBContainerSnapshot *snapshot=SBBackendContainers(containers);
    Check(snapshot.available && snapshot.containers.count==2 && Dispatches==dispatches,@"snapshot has no actions");
    Check([snapshot.activeIdentifier isEqual:@"9001"],@"active cached stable ID");
    Check([snapshot.containers[0].identifier isEqual:@"41"] && [snapshot.containers[1].identifier isEqual:@"9001"],@"IDs never inferred from identical labels");
    Check([snapshot.containers[0].proxyTitle isEqual:@"North"] && [snapshot.containers[0].profileIdentifier isEqual:@"saved-profile"] && [snapshot.containers[0].folderName isEqual:@"Research"],@"reviewed optional metadata");
    [mutableName appendString:@" changed"];
    Check([snapshot.containers[0].name isEqual:@"Same label"],@"snapshot copies strings");
    Check([SBBackendContainerAtIndexPath(containers,[NSIndexPath indexPathForRow:0 inSection:0]).identifier isEqual:@"9001"],@"index path uses backend model mapping not array index");
    Check(!SBBackendContainerAtIndexPath(containers,[NSIndexPath indexPathForRow:1 inSection:0]),@"unknown index path has no inferred ID");
    containers.rows=@[b,a];
    Check(SBBackendInvokeContainerAction(containers,@"container.rename",@"41",&reason) && LastContainer==a,@"rename resolves stable ID after reorder");
    Check(SBBackendInvokeContainerAction(containers,@"container.delete",@"41",&reason) && LastContainer==a,@"delete resolves stable ID after reorder");
    Check(!SBBackendInvokeContainerAction(containers,@"container.delete",@"9001",&reason),@"active container delete remains unavailable");
    for (NSString *action in @[@"container.switch",@"container.apps",@"container.proxy",@"container.export",@"container.newFolder",@"container.removeFolder"])
        Check(SBBackendInvokeContainerAction(containers,action,@"41",&reason) && LastContainer==a,@"reviewed object action keeps exact model sender");
    Check(!SBBackendInvokeContainerAction(containers,@"performSwitchToContainer:",@"41",&reason),@"private container worker refused");
    Check(!SBBackendInvokeContainerAction(containers,@"container.rename",@"041",&reason),@"noncanonical identifier refused");
    Check(!SBBackendInvokeContainerAction(containers,@"container.rename",@"9223372036854775808",&reason),@"overflow identifier refused");
    containers.rows=@[b]; dispatches=Dispatches;
    Check(!SBBackendInvokeContainerAction(containers,@"container.rename",@"41",&reason) && Dispatches==dispatches,@"deleted identifier rejected");
    containers.rows=@[a,b]; containers.listReads=0; containers.disappearAfterRead=2;
    Check(!SBBackendInvokeContainerAction(containers,@"container.rename",@"41",&reason) && Dispatches==dispatches,@"disappearance after snapshot rejected");
    containers.disappearAfterRead=0; containers.rows=@[a,a];
    Check(!SBBackendContainers(containers).available && !SBBackendInvokeContainerAction(containers,@"container.rename",@"41",&reason),@"duplicate identifiers rejected");
    containers.rows=@[a,b]; containers.changeSelection=YES;
    Check(!SBBackendContainers(containers).available,@"selection changes rejected"); containers.changeSelection=NO;
    a.apps=@[@"com.reddit.Reddit",@"com.reddit.Reddit"];
    Check(!SBBackendContainers(containers).available,@"duplicate app membership rejected");
    a.apps=@[@"../other"];
    Check(!SBBackendContainers(containers).available,@"invalid app membership rejected");
    a.apps=nil; snapshot=SBBackendContainers(containers);
    Check(snapshot.available && !snapshot.containers[0].appMembershipAvailable,@"missing membership remains explicitly unavailable");
    a.name=@"bad\nname";
    Check(!SBBackendContainers(containers).available,@"control characters rejected"); a.name=@"valid";
    a.proxyTitle=(id)@17; a.spoofProfileID=(id)@[]; snapshot=SBBackendContainers(containers);
    Check(snapshot.available && !snapshot.containers[0].proxyTitle && !snapshot.containers[0].profileIdentifier,@"optional invalid field does not invalidate list");
    containers.rows=@[]; snapshot=SBBackendContainers(containers);
    Check(snapshot.available && snapshot.containers.count==0 && !snapshot.activeIdentifier,@"empty list distinct from unavailable");
    Check(SBBackendInvoke(containers,@"containers.import",nil,&reason),@"original import entry available");
    Check(SBBackendInvoke(containers,@"containers.default",nil,&reason),@"original default confirmation entry available");
}

@interface AdapterFixtureDelegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AdapterFixtureDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options; self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new]; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(),^{
        @try { RunTests(); } @catch (NSException *exception) { if (!Failures) Failures=[NSMutableArray array]; [Failures addObject:[@"fixture exception: " stringByAppendingString:exception.name]]; }
        NSDictionary *report=@{@"ok":@(Failures.count==0),@"checks":@(Checks),@"failures":Failures ?: @[],@"evidence":@"synthetic adapter ABI and UI actions only"};
        NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"backend-adapter-result.json"] atomically:YES];
    }); return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AdapterFixtureDelegate.class)); } }
