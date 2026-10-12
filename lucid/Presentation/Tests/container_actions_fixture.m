// Actual container UI/adapter with inert models and original-shaped entrypoints.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SBContainersView.h"
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import "LBXIsolationViewController.h"
static NSUInteger Checks,DeleteEntries,RenameEntries,SwitchEntries,Completions;
static BOOL OptimisticCompletion;
static NSMutableArray *Failures;
static id LastNativeObject;
static char SwipeHandlerKey,AlertHandlerKey;
static void Check(BOOL ok,NSString *name){Checks++;if(!ok)[Failures addObject:name];}
static BOOL Wait(BOOL(^condition)(void)){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:4];while(!condition()&&end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];return condition();}
static void Settle(void){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:.1];while(end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
static UIView *Find(UIView *root,NSString *key){if([root.accessibilityIdentifier isEqual:key])return root;for(UIView *child in root.subviews){UIView *found=Find(child,key);if(found)return found;}return nil;}
static UITableView *Table(UIView *root){if([root isKindOfClass:UITableView.class])return (id)root;for(UIView *child in root.subviews){UITableView *found=Table(child);if(found)return found;}return nil;}
static id (*OriginalSwipe)(id,SEL,UIContextualActionStyle,NSString *,void(^)(UIContextualAction *,UIView *,void(^)(BOOL)));
static id CaptureSwipe(id cls,SEL selector,UIContextualActionStyle style,NSString *title,void(^handler)(UIContextualAction *,UIView *,void(^)(BOOL))){id action=OriginalSwipe(cls,selector,style,title,handler);objc_setAssociatedObject(action,&SwipeHandlerKey,handler,OBJC_ASSOCIATION_COPY_NONATOMIC);return action;}
static id (*OriginalAlert)(id,SEL,NSString *,UIAlertActionStyle,void(^)(UIAlertAction *));
static id CaptureAlert(id cls,SEL selector,NSString *title,UIAlertActionStyle style,void(^handler)(UIAlertAction *)){id action=OriginalAlert(cls,selector,title,style,handler);objc_setAssociatedObject(action,&AlertHandlerKey,handler,OBJC_ASSOCIATION_COPY_NONATOMIC);return action;}
static void InvokeSwipe(UIContextualAction *action,UIView *view){void(^handler)(UIContextualAction *,UIView *,void(^)(BOOL))=objc_getAssociatedObject(action,&SwipeHandlerKey);Check(handler!=nil,@"actual contextual action has a handler");if(handler)handler(action,view,^(BOOL success){Completions++;OptimisticCompletion|=success;});}
static NSDictionary *Metadata(void){return @{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"};}
@implementation LBXIsolationViewController @end
@interface _Xv8i:NSObject
@property(nonatomic) long long containerID;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSArray *apps;
@end
@implementation _Xv8i @end
@interface _Xc9m:UIViewController
@property(nonatomic,copy) NSArray *containers;
@property(nonatomic) long long activeContainerID;
@property(nonatomic,strong) SBContainersView *surface;
@end
@implementation _Xc9m
- (void)viewDidLoad{[super viewDidLoad];self.surface=[[SBContainersView alloc] initWithOwner:self];self.surface.frame=self.view.bounds;self.surface.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:self.surface];}
- (void)confirmSwitchToContainer:(id)row{SwitchEntries++;LastNativeObject=row;}
- (void)confirmDeleteContainer:(_Xv8i *)row{
    DeleteEntries++;LastNativeObject=row;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Native deletion confirmation" message:row.name preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){NSMutableArray *rows=[self.containers mutableCopy];[rows removeObject:row];self.containers=rows;[self.surface refresh];}]];
    [self presentViewController:alert animated:NO completion:nil];
}
- (void)renameContainer:(_Xv8i *)row{
    RenameEntries++;LastNativeObject=row;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Native rename prompt" message:row.name preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=row.name;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weak=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){row.name=weak.textFields.firstObject.text;[self.surface refresh];}]];
    [self presentViewController:alert animated:NO completion:nil];
}
@end
static _Xv8i *Record(long long identifier,NSString *name){_Xv8i *row=[_Xv8i new];row.containerID=identifier;row.name=name;row.apps=@[@"com.fixture.app"];return row;}
@interface ContainerActionsApp:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UITabBarController *tabs;
@property(nonatomic,strong) _Xc9m *owner;
@end
@implementation ContainerActionsApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options{
    (void)application;(void)options;Failures=[NSMutableArray array];SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    Method swipe=class_getClassMethod(UIContextualAction.class,@selector(contextualActionWithStyle:title:handler:));OriginalSwipe=(void *)method_setImplementation(swipe,(IMP)CaptureSwipe);
    Method alert=class_getClassMethod(UIAlertAction.class,@selector(actionWithTitle:style:handler:));OriginalAlert=(void *)method_setImplementation(alert,(IMP)CaptureAlert);
    self.owner=[_Xc9m new];self.owner.containers=@[Record(99,@"Mária · Travel"),Record(41,@"Work • Saved name"),Record(73,@"Mária · Travel")];self.owner.activeContainerID=41;
    self.tabs=[UITabBarController new];self.tabs.viewControllers=@[[[UINavigationController alloc] initWithRootViewController:self.owner],[UIViewController new]];
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.window.rootViewController=self.tabs;[self.window makeKeyAndVisible];
    [self performSelector:@selector(run) withObject:nil afterDelay:.1];return YES;
}
- (UIContextualAction *)action:(BOOL)delete row:(NSInteger)row{
    UITableView *table=Table(self.owner.surface);NSIndexPath *index=[NSIndexPath indexPathForRow:row inSection:0];
    UISwipeActionsConfiguration *configuration=delete?[table.delegate tableView:table trailingSwipeActionsConfigurationForRowAtIndexPath:index]:[table.delegate tableView:table leadingSwipeActionsConfigurationForRowAtIndexPath:index];
    if(configuration){Check(configuration.actions.count==1&&!configuration.performsFirstActionWithFullSwipe,@"one explicit action; full swipe disabled");Check(configuration.actions.firstObject.style==(delete?UIContextualActionStyleDestructive:UIContextualActionStyleNormal),@"native destructive role only for Delete");}
    return configuration.actions.firstObject;
}
- (void)dismiss{[self.owner dismissViewControllerAnimated:NO completion:nil];Check(Wait(^BOOL{return !self.owner.presentedViewController;}),@"synthetic native confirmation dismissed");Settle();}
- (void)run{
    _Xc9m *owner=self.owner;UITableView *table=Table(owner.surface);NSArray *original=owner.containers;_Xv8i *active=original[1],*target=original[2];
    Check(owner.view.window!=nil,@"Containers is attached before user actions");
    Check([((UILabel *)Find(owner.surface,@"socialbox.containers.selectedName")).text isEqual:@"Selected: Work • Saved name"],@"selected heading shows exact saved name");
    for(NSInteger row=0;row<3;row++){UITableViewCell *cell=[table.dataSource tableView:table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];UIListContentConfiguration *content=(id)cell.contentConfiguration;Check([content.text isEqual:row==0?active.name:target.name],@"duplicate display names remain exact and do not become IDs");Check(content.textProperties.numberOfLines==0,@"row names retain full wrapping");}
    Check([self action:YES row:0]==nil&&DeleteEntries==0,@"active container has no delete action");
    UIContextualAction *rename=[self action:NO row:0];InvokeSwipe(rename,table);Check(RenameEntries==1&&LastNativeObject==active,@"active container may use existing rename prompt");
    UIAlertController *prompt=(id)owner.presentedViewController;Check([prompt.textFields.firstObject.text isEqual:active.name],@"native rename prompt starts with saved name");[self dismiss];Check([active.name isEqual:@"Work • Saved name"],@"cancel rename leaves saved name unchanged");
    UIContextualAction *delete=[self action:YES row:1];owner.containers=@[target,original[0],active];
    _Xv8i *replacement=Record(73,target.name);owner.containers=@[original[0],active,replacement];
    InvokeSwipe(delete,table);Check(DeleteEntries==1&&LastNativeObject==replacement,@"delete re-resolves same stable ID after reorder and replacement");
    Check(owner.containers.count==3&&[table.dataSource tableView:table numberOfRowsInSection:0]==3&&!OptimisticCompletion,@"opening native confirmation never removes a row or reports deletion");
    Check([owner.presentedViewController.title isEqual:@"Native deletion confirmation"],@"one original confirmation is preserved");[self dismiss];
    InvokeSwipe(delete,table);Check(DeleteEntries==1&&owner.containers.count==3,@"cancelled swipe callback cannot be replayed");
    delete=[self action:YES row:1];owner.containers=@[original[0],active];InvokeSwipe(delete,table);Check(DeleteEntries==1,@"removed ID cannot retarget another row");[self dismiss];
    owner.containers=@[original[0],active,replacement];[owner.surface refresh];delete=[self action:YES row:1];owner.activeContainerID=73;InvokeSwipe(delete,table);Check(DeleteEntries==1,@"newly active target refuses captured Delete");[self dismiss];owner.activeContainerID=41;[owner.surface refresh];
    delete=[self action:YES row:1];owner.containers=@[replacement,replacement,active];InvokeSwipe(delete,table);Check(DeleteEntries==1,@"ambiguous fresh metadata refuses captured Delete");[self dismiss];owner.containers=@[original[0],active,replacement];[owner.surface refresh];
    delete=[self action:YES row:1];self.tabs.selectedIndex=1;Settle();InvokeSwipe(delete,table);Check(DeleteEntries==1,@"offscreen swipe cannot invoke original deletion");self.tabs.selectedIndex=0;Settle();
    delete=[self action:YES row:1];[owner.navigationController pushViewController:[UIViewController new] animated:NO];Settle();InvokeSwipe(delete,table);Check(DeleteEntries==1,@"stale navigation refuses captured action");[owner.navigationController popViewControllerAnimated:NO];Settle();
    delete=[self action:YES row:1];SBBackendFixtureConfigure(@{},NSBundle.mainBundle.executablePath);InvokeSwipe(delete,table);Check(DeleteEntries==1,@"changed host metadata refuses action");[self dismiss];SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    rename=[self action:NO row:0];InvokeSwipe(rename,table);prompt=(id)owner.presentedViewController;prompt.textFields.firstObject.text=@"Osobný účet ✨ — saved by the native rename flow";
    void(^save)(UIAlertAction *)=objc_getAssociatedObject(prompt.actions.lastObject,&AlertHandlerKey);Check(save!=nil,@"synthetic original rename retains Save action");if(save)save(prompt.actions.lastObject);[self dismiss];
    UITableViewCell *cell=[table.dataSource tableView:table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    Check([((UIListContentConfiguration *)cell.contentConfiguration).text isEqual:active.name]&&[((UILabel *)Find(owner.surface,@"socialbox.containers.selectedName")).text hasSuffix:active.name],@"fresh native name appears in row and selected heading");
    delete=[self action:YES row:1];InvokeSwipe(delete,table);prompt=(id)owner.presentedViewController;void(^remove)(UIAlertAction *)=objc_getAssociatedObject(prompt.actions.lastObject,&AlertHandlerKey);if(remove)remove(prompt.actions.lastObject);[self dismiss];
    Check(DeleteEntries==2&&owner.containers.count==2&&[table.dataSource tableView:table numberOfRowsInSection:0]==2&&!OptimisticCompletion,@"only synthetic native confirmation completion updates visible inventory");
    Check(owner.activeContainerID==41&&SwitchEntries==0,@"gestures never invoke switching or change selected ID");
    owner.containers=@[];owner.activeContainerID=-1;[owner.surface refresh];Check(Find(owner.surface,@"socialbox.containers.selectedName").hidden&&Find(owner.surface,@"socialbox.containers.swipeHint").hidden,@"empty state shows no invented selected name or swipe hint");
    owner.containers=original;owner.activeContainerID=41;[owner.surface refresh];[self.window layoutIfNeeded];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:owner.view.bounds];[[renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context){[owner.view drawViewHierarchyInRect:owner.view.bounds afterScreenUpdates:YES];}] writeToFile:[documents stringByAppendingPathComponent:@"container-actions.png"] atomically:YES];
    NSDictionary *result=@{@"ok":@((BOOL)!Failures.count),@"assertions":@(Checks),@"failures":Failures,@"nativeDeleteEntries":@(DeleteEntries),@"nativeRenameEntries":@(RenameEntries),@"contextualCompletions":@(Completions),@"realContainerMutation":@NO,@"phoneAction":@NO};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"container-actions-result.json"] atomically:YES];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ContainerActionsApp.class));}}
