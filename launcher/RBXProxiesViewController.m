#import "RBXAppScope.h"
#import "RBXProxiesViewController.h"
#import "RBXProxyLibrary.h"
#import "RBXLauncherIPC.h"
#import "RBXSettingsViewController.h"
#import "RBXAppearance.h"
#import "RBXSetupChecklist.h"
#import "RBXSecureConfig.h"
#import "RBXHTTPProxy.h"

@interface RBXProxyListImporter : UIViewController <UITextViewDelegate>
@property UITextView *input;
@property UIScrollView *scroll;
@property UILabel *summary;
@property UITextView *details;
@property UIButton *importButton;
@property NSDictionary *preview;
@property(copy) void (^didImport)(NSUInteger);
@end
@implementation RBXProxyListImporter
- (void)viewDidLoad {
 [super viewDidLoad];self.navigationItem.title=@"Import proxies";self.view.backgroundColor=RBXCanvasColor();
 self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
 UIScrollView *scroll=[UIScrollView new];self.scroll=scroll;scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:scroll];
 UIStackView *page=RBXVerticalStack(@[],18);page.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:page];
 [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],[page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],[page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
 UIStackView *inputCard=RBXFormSection(page,@"One HTTP proxy per line",@"Paste host:port, host:port:user:password or http://user:password@host:port. SOCKS, HTTPS-to-proxy and app-specific configuration files are not supported.");
 self.input=[UITextView new];self.input.delegate=self;self.input.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.input.adjustsFontForContentSizeCategory=YES;self.input.backgroundColor=UIColor.tertiarySystemGroupedBackgroundColor;self.input.textColor=UIColor.labelColor;self.input.layer.cornerRadius=12;self.input.textContainerInset=UIEdgeInsetsMake(12,10,12,10);self.input.autocorrectionType=UITextAutocorrectionTypeNo;self.input.autocapitalizationType=UITextAutocapitalizationTypeNone;self.input.smartQuotesType=UITextSmartQuotesTypeNo;self.input.smartDashesType=UITextSmartDashesTypeNo;self.input.accessibilityLabel=@"Proxy list";[self.input.heightAnchor constraintEqualToConstant:200].active=YES;[inputCard addArrangedSubview:self.input];
 UIButton *paste=[UIButton buttonWithType:UIButtonTypeSystem];[paste setTitle:@"Paste from clipboard" forState:UIControlStateNormal];RBXStyleButton(paste,NO);[paste addTarget:self action:@selector(pasteList) forControlEvents:UIControlEventTouchUpInside];[inputCard addArrangedSubview:paste];
 UIButton *review=[UIButton buttonWithType:UIButtonTypeSystem];[review setTitle:@"Preview import" forState:UIControlStateNormal];RBXStyleButton(review,NO);[review addTarget:self action:@selector(previewImport) forControlEvents:UIControlEventTouchUpInside];[page addArrangedSubview:review];
 UIStackView *result=RBXFormSection(page,@"Review",@"Nothing is saved until you confirm. Duplicates are skipped. Any invalid line blocks the whole import.");
 self.summary=RBXLabel(@"Paste a list, then preview it.",UIFontTextStyleBody,NO);[result addArrangedSubview:self.summary];
 self.details=[UITextView new];self.details.editable=NO;self.details.backgroundColor=UIColor.clearColor;self.details.textColor=UIColor.secondaryLabelColor;self.details.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.details.adjustsFontForContentSizeCategory=YES;self.details.accessibilityLabel=@"Import preview";[self.details.heightAnchor constraintEqualToConstant:180].active=YES;self.details.hidden=YES;[result addArrangedSubview:self.details];
 self.importButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.importButton setTitle:@"Import reviewed proxies" forState:UIControlStateNormal];RBXStyleButton(self.importButton,YES);self.importButton.enabled=NO;[self.importButton addTarget:self action:@selector(confirmImport) forControlEvents:UIControlEventTouchUpInside];[page addArrangedSubview:self.importButton];
 [page addArrangedSubview:RBXLabel(@"Import only saves the library. Choose Use and test afterwards. Container-specific cloud proxy assignments are unchanged.",UIFontTextStyleFootnote,YES)];
}
- (void)invalidatePreview {self.preview=nil;self.importButton.enabled=NO;self.summary.text=@"List changed. Preview it before importing.";self.details.text=@"";self.details.hidden=YES;}
- (void)textViewDidChange:(UITextView *)textView {[self invalidatePreview];}
- (void)pasteList {self.input.text=UIPasteboard.generalPasteboard.string?:@"";[self invalidatePreview];}
- (void)previewImport {
 [self.view endEditing:YES];NSError *error=nil;self.preview=[RBXProxyLibrary importPreviewForText:self.input.text error:&error];
 self.importButton.enabled=[self.preview[@"canImport"] boolValue];self.details.hidden=!self.preview;
 if(!self.preview){self.summary.text=error.localizedDescription?:@"The list could not be read.";return;}
 self.summary.text=[NSString stringWithFormat:@"%@ new · %@ duplicates · %@ invalid",self.preview[@"newCount"],self.preview[@"duplicateCount"],self.preview[@"invalidCount"]];
 NSMutableArray *lines=[NSMutableArray array];
 if([self.preview[@"capacityExceeded"] boolValue])[lines addObject:@"The result exceeds 100 saved proxies. Shorten the list; nothing has been imported."];
 for(NSDictionary *issue in self.preview[@"issues"])[lines addObject:[NSString stringWithFormat:@"Line %@: %@",issue[@"line"],issue[@"message"]]];
 for(NSDictionary *entry in self.preview[@"entries"]) {
  NSDictionary *endpoint=RBXParseHTTPProxyURL(entry[@"proxyURL"]);
  [lines addObject:[NSString stringWithFormat:@"+ %@%@",entry[@"name"],[endpoint[@"username"] length]?@" · with credentials":@""]];
 }
 if(!lines.count)[lines addObject:@"No new proxies. Blank lines are ignored; existing endpoints and identical credentials are duplicates."];
 self.details.text=[lines componentsJoinedByString:@"\n"];
 [self.view layoutIfNeeded];
 CGRect review=[self.summary.superview convertRect:self.summary.superview.bounds toView:self.scroll];
 CGRect button=[self.importButton convertRect:self.importButton.bounds toView:self.scroll];
 review.size.height=MAX(review.size.height,button.origin.y+button.size.height-review.origin.y);
 [self.scroll scrollRectToVisible:review animated:YES];
}
- (void)confirmImport {
 if(![self.preview[@"canImport"] boolValue])return;
 UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Import %@ proxies?",self.preview[@"newCount"]] message:@"All new entries are saved together. Your selected proxy and existing container assignments stay unchanged." preferredStyle:UIAlertControllerStyleAlert];
 [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
 [alert addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self commitImport];}]];
 [self presentViewController:alert animated:YES completion:nil];
}
- (void)commitImport {
 NSError *error=nil;NSUInteger count=[self.preview[@"newCount"] unsignedIntegerValue];
 if(![RBXProxyLibrary importText:self.input.text reviewedPreview:self.preview error:&error]) {
  self.preview=nil;self.importButton.enabled=NO;self.summary.text=error.localizedDescription?:@"Could not save the list. Nothing was imported; preview again.";return;
 }
 self.input.text=@"";self.preview=nil;self.importButton.enabled=NO;
 if(self.didImport)self.didImport(count);[self.navigationController popViewControllerAnimated:YES];
}
@end

@interface RBXProxyEditor : UIViewController
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property NSDictionary *entry;
@property UITextField *nameField,*urlField,*rotateField,*headerField,*tokenField;
@property UISegmentedControl *method;
@property UIStackView *advanced;
@property UIButton *advancedButton;
@end
@implementation RBXProxyEditor
- (NSString *)requestOwner { return RBXAppScopedPreferenceKey(@"proxy-library", self.appDescriptor); }
- (UITextField *)field:(NSString *)placeholder value:(NSString *)value stack:(UIStackView *)stack {
 UITextField *f=[UITextField new];f.placeholder=placeholder;f.text=value;RBXStyleField(f);
 f.autocorrectionType=UITextAutocorrectionTypeNo;f.autocapitalizationType=UITextAutocapitalizationTypeNone;
 f.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];f.adjustsFontForContentSizeCategory=YES;
 [stack addArrangedSubview:f];return f;
}
- (void)viewDidLoad {
 [super viewDidLoad];self.navigationItem.title=self.entry?@"Edit proxy":@"Add proxy";self.view.backgroundColor=RBXCanvasColor();
 self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
 self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
 UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:scroll];
 UIStackView *page=RBXVerticalStack(@[],20);page.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:page];
 [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],[page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],[page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
 UIStackView *fields=RBXFormSection(page,@"Proxy",nil);
 [fields addArrangedSubview:RBXLabel(@"Name",UIFontTextStyleSubheadline,NO)];self.nameField=[self field:@"My proxy" value:self.entry[@"name"] stack:fields];
 [fields addArrangedSubview:RBXLabel(@"HTTP proxy",UIFontTextStyleSubheadline,NO)];self.urlField=[self field:@"host:port:user:password" value:self.entry[@"proxyURL"] stack:fields];self.urlField.keyboardType=UIKeyboardTypeURL;
 [fields addArrangedSubview:RBXLabel(@"Paste host:port:user:password or an http:// address. The full address stays visible.",UIFontTextStyleFootnote,YES)];
 [fields addArrangedSubview:RBXLabel(@"Rotate link · optional",UIFontTextStyleSubheadline,NO)];self.rotateField=[self field:@"https://…" value:self.entry[@"rotationURL"] stack:fields];self.rotateField.keyboardType=UIKeyboardTypeURL;
 self.advancedButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.advancedButton setTitle:@"Advanced options" forState:UIControlStateNormal];[self.advancedButton addTarget:self action:@selector(toggleAdvanced) forControlEvents:UIControlEventTouchUpInside];[page addArrangedSubview:self.advancedButton];
 self.advanced=RBXFormSection(page,@"Rotation options",@"Only needed if your provider requires them.");
 self.headerField=[self field:@"Header name" value:self.entry[@"authHeader"]?:@"Authorization" stack:self.advanced];
 self.tokenField=[self field:@"Authorization token · optional" value:self.entry[@"authorization"] stack:self.advanced];self.tokenField.secureTextEntry=YES;
 self.method=[[UISegmentedControl alloc] initWithItems:@[@"GET",@"POST"]];self.method.selectedSegmentIndex=[self.entry[@"method"] isEqual:@"POST"]?1:0;[self.advanced addArrangedSubview:self.method];self.advanced.hidden=YES;
}
- (void)toggleAdvanced {self.advanced.hidden=!self.advanced.hidden;[self.advancedButton setTitle:self.advanced.hidden?@"Advanced options":@"Hide advanced options" forState:UIControlStateNormal];}
- (void)save {
 NSString *name=[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 NSDictionary *entry=@{@"id":self.entry[@"id"]?:NSUUID.UUID.UUIDString,@"name":name.length?name:@"My proxy",@"proxyURL":self.urlField.text?:@"",@"rotationURL":self.rotateField.text?:@"",@"authHeader":self.headerField.text?:@"Authorization",@"authorization":self.tokenField.text?:@"",@"method":self.method.selectedSegmentIndex==1?@"POST":@"GET"};
 NSError *error=nil;
 if(![RBXProxyLibrary saveEntry:entry error:&error]){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Could not save proxy" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];return;}
 if([[RBXProxyLibrary selectedIdentifier:nil] isEqual:entry[@"id"]]) [RBXLauncherIPC sendActionReturningRequestId:@"configurationChanged" values:@{} notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
 [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface RBXProxiesViewController () <UISearchResultsUpdating>
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property NSArray<NSDictionary *> *proxies;
@property NSString *selected;
@property UISearchController *search;
@property NSUInteger totalCount;
@property NSString *feedback;
@property NSTimer *timer;
@property NSDictionary *deviceState;
@end
@implementation RBXProxiesViewController
- (instancetype)init { return [self initWithAppType:@"reddit"]; }
- (instancetype)initWithAppType:(NSString *)appType {
 NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
 if (!descriptor) return nil;
 if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _appDescriptor = descriptor;
 return self;
}
- (NSString *)requestOwner { return RBXAppScopedPreferenceKey(@"proxy-library", self.appDescriptor); }
- (void)viewDidLoad {
 [super viewDidLoad];self.navigationItem.title=@"Proxies";self.tableView.backgroundColor=RBXCanvasColor();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=80;
 self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"Search saved proxies";self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;

 self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addMenu)];self.navigationItem.rightBarButtonItem.accessibilityLabel=@"Add or import proxies";
 self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self reload];__weak typeof(self) weak=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t){[weak reload];}];}
- (void)viewWillDisappear:(BOOL)animated {[super viewWillDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {[self reload];}
- (void)reload {
 NSMutableDictionary *state=[RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"], self.appDescriptor) mutableCopy]?:[NSMutableDictionary dictionary];
 state[@"configuration"]=[RBXSecureConfig safeSummary];self.deviceState=state;
 NSError *error=nil;self.proxies=[RBXProxyLibrary entries:&error]?:@[];self.selected=[RBXProxyLibrary selectedIdentifier:nil];
 self.totalCount=self.proxies.count;
 NSString *query=[self.search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if(query.length) self.proxies=[self.proxies filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings){return [row[@"name"] localizedCaseInsensitiveContainsString:query] || [row[@"proxyURL"] localizedCaseInsensitiveContainsString:query];}]];
 for(NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]){NSDictionary *result=[RBXLauncherIPC requestResultForId:request[@"requestId"]];if(result){self.feedback=result[@"message"];[RBXLauncherIPC finishObservingRequestId:request[@"requestId"] owner:self.requestOwner];}}
 self.navigationItem.prompt=error.localizedDescription;
 [self.tableView reloadData];
}
- (void)addProxy {RBXProxyEditor *editor=[RBXProxyEditor new];editor.appDescriptor=self.appDescriptor;[self.navigationController pushViewController:editor animated:YES];}
- (void)importList {
 RBXProxyListImporter *controller=[RBXProxyListImporter new];__weak typeof(self) weak=self;
 controller.didImport=^(NSUInteger count){weak.feedback=[NSString stringWithFormat:@"%lu proxies imported. Choose one, then Use and test.",(unsigned long)count];};
 [self.navigationController pushViewController:controller animated:YES];
}
- (void)addMenu {
 UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Add proxies" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
 [menu addAction:[UIAlertAction actionWithTitle:@"Add one proxy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self addProxy];}]];
 [menu addAction:[UIAlertAction actionWithTitle:@"Paste a list" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self importList];}]];
 [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
 menu.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;[self presentViewController:menu animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return MAX((NSUInteger)1,self.proxies.count);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return [NSString stringWithFormat:@"Proxies · %lu saved",(unsigned long)self.totalCount];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
 NSString *text=@"Selected means the device's saved proxy. Containers may have a separate cloud assignment. Tap a proxy to use, test, edit or delete it. A saved or tested proxy alone is not proof of network isolation.";
 return self.feedback.length?[text stringByAppendingFormat:@"\n\n%@",self.feedback]:text;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
 if(!self.proxies.count) {
  UITableViewCell *cell=[UITableViewCell new];cell.selectionStyle=UITableViewCellSelectionStyleNone;cell.backgroundColor=UIColor.clearColor;
  UIStackView *page=RBXVerticalStack(@[],14);page.translatesAutoresizingMaskIntoConstraints=NO;[cell.contentView addSubview:page];
  UIStackView *card=RBXFormSection(page,self.totalCount?@"No matching proxies":@"Add your first proxy",self.totalCount?@"Try a different name or endpoint in search.":@"Keep your proxies together, then choose one and test its connection. An optional rotate link can be added in Edit.");
  if(!self.totalCount)for(NSString *title in @[@"Add one proxy",@"Paste a list"]) {
   UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:title forState:UIControlStateNormal];RBXStyleButton(button,[title isEqual:@"Add one proxy"]);[button addTarget:self action:[title isEqual:@"Add one proxy"]?@selector(addProxy):@selector(importList) forControlEvents:UIControlEventTouchUpInside];[card addArrangedSubview:button];
  }
  [NSLayoutConstraint activateConstraints:@[[page.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],[page.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],[page.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],[page.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor]]];return cell;
 }
 UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];NSDictionary *row=self.proxies[indexPath.row];
 cell.textLabel.text=row[@"name"];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.imageView.image=[UIImage systemImageNamed:@"network"];cell.imageView.tintColor=RBXAccentColor();cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
 cell.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@",row[@"proxyURL"],[row[@"id"] isEqual:self.selected]?@"Selected for device":([row[@"rotationURL"] length]?@"Rotation available":@"No rotation link")];cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.lineBreakMode=NSLineBreakByCharWrapping;cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
 BOOL selected=[row[@"id"] isEqual:self.selected];
 UIBackgroundConfiguration *background=[UIBackgroundConfiguration listPlainCellConfiguration];background.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;background.cornerRadius=20;background.backgroundInsets=NSDirectionalEdgeInsetsMake(5,0,5,0);background.strokeColor=selected?RBXAccentColor():UIColor.separatorColor;background.strokeWidth=selected?1.5:0.5;cell.backgroundConfiguration=background;
 if(selected) {
  NSDictionary *test=RBXSetupDictionary(self.deviceState[@"configurationTest"]);
  BOOL verified=RBXProxyTestCurrent(self.deviceState,test,NSDate.date.timeIntervalSince1970) && [test[@"ok"] isEqual:@YES];
  cell.detailTextLabel.text=[cell.detailTextLabel.text stringByAppendingString:verified ? @"\n✓ Connection verified · rechecked on every Open" : @"\n✕ Connection not verified · choose Use and test"];
  cell.detailTextLabel.textColor=verified ? UIColor.systemGreenColor : UIColor.systemRedColor;
 }
 cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)message:(NSString *)message {UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Proxy" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (void)use:(NSDictionary *)row test:(BOOL)test {
 if([RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count){[self message:@"Wait for the current proxy operation to finish."];return;}
 NSError *error=nil;if(![RBXProxyLibrary selectIdentifier:row[@"id"] error:&error]){[self message:error.localizedDescription];return;}
 if(self.didSelectProxy) self.didSelectProxy();
 NSString *request=[RBXLauncherIPC sendActionReturningRequestId:test?@"testConfiguration":@"configurationChanged" values:@{} notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
 self.feedback=request?(test?@"Testing selected proxy…":@"Applying selected proxy…"):@"Saved, but the daemon request could not be sent. Try again.";[self reload];
}
- (void)delete:(NSDictionary *)row {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Delete proxy?" message:[row[@"id"] isEqual:self.selected]?@"This is the selected proxy. Connections will stay blocked until you select another one.":@"Remove this proxy from the saved list?" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
 [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){NSError *error=nil;BOOL active=[row[@"id"] isEqual:[RBXProxyLibrary selectedIdentifier:nil]];if(![RBXProxyLibrary deleteIdentifier:row[@"id"] error:&error]){[self message:error.localizedDescription];return;}if(active)[RBXLauncherIPC sendActionReturningRequestId:@"configurationChanged" values:@{} notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];self.feedback=nil;[self reload];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
 [tableView deselectRowAtIndexPath:indexPath animated:YES];if(indexPath.row>=self.proxies.count)return;NSDictionary *row=self.proxies[indexPath.row];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:row[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
 [a addAction:[UIAlertAction actionWithTitle:@"Use proxy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *v){[self use:row test:NO];}]];
 [a addAction:[UIAlertAction actionWithTitle:@"Use and test" style:UIAlertActionStyleDefault handler:^(UIAlertAction *v){[self use:row test:YES];}]];
 [a addAction:[UIAlertAction actionWithTitle:@"Edit" style:UIAlertActionStyleDefault handler:^(UIAlertAction *v){RBXProxyEditor *editor=[RBXProxyEditor new];editor.appDescriptor=self.appDescriptor;editor.entry=row;[self.navigationController pushViewController:editor animated:YES];}]];
 [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *v){[self delete:row];}]];
 [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
 a.popoverPresentationController.sourceView=[tableView cellForRowAtIndexPath:indexPath];a.popoverPresentationController.sourceRect=a.popoverPresentationController.sourceView.bounds;[self presentViewController:a animated:YES completion:nil];
}
@end
