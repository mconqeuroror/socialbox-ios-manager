// Actual UIKit editor, with inert IPC and private draft storage. No daemon/device claims.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RBXIdentityViewController.h"
#import "RBXCatalogPickerViewController.h"
#import "RBXLocationPickerViewController.h"
#import <MapKit/MapKit.h>
#import "RBXLauncherIPC.h"
#import "RBXSecureConfig.h"
#import "RBXIdentityHelp.h"

@interface RBXIdentityViewController (FixtureSurface)
- (NSDictionary *)catalog;
- (NSDictionary *)choices;
- (void)loadResult;
- (void)chooseModel;
- (void)chooseIOS;
- (void)chooseRegion;
- (void)chooseCarrier;
- (void)chooseCity;
- (void)chooseLanguage;
- (void)fillCoordinatesForSelectedCity;
- (void)checkConsistency;
- (void)applyIdentity;
- (void)choicesChanged;
- (void)saveSentinelSettings;
- (void)randomFill;
- (void)reloadIdentity;
- (void)toggleAdvancedGroups;
- (void)chooseLocationMap;
@end

@interface RBXLocationPickerViewController (FixtureSurface)
- (void)selectLatitude:(NSString *)latitude longitude:(NSString *)longitude;
- (void)applyLocation;
- (void)cancel;
- (BOOL)textFieldShouldReturn:(UITextField *)field;
- (void)mapViewWillStartLoadingMap:(MKMapView *)map;
- (void)mapViewDidFailLoadingMap:(MKMapView *)map withError:(NSError *)error;
- (void)mapViewDidFinishRenderingMap:(MKMapView *)map fullyRendered:(BOOL)rendered;
@end

static NSMutableArray *requests, *failures;
static NSMutableDictionary *receipts, *drafts;
static NSUInteger checks;
static BOOL rejectSend;
static NSDictionary *fixtureCatalog;

@implementation RBXLauncherIPC
+ (NSString *)sendActionReturningRequestId:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)notification owner:(NSString *)owner appType:(NSString *)appType {
    if (rejectSend) return nil;
    NSString *requestID = NSUUID.UUID.UUIDString;
    [requests addObject:@{@"requestId":requestID, @"action":action, @"values":values,
                         @"owner":owner, @"appType":appType, @"pending":@YES}];
    return requestID;
}
+ (NSDictionary *)requestResultForId:(NSString *)requestID { return receipts[requestID]; }
+ (NSArray *)pendingRequestsForOwner:(NSString *)owner {
    return [requests filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *request, NSDictionary *bindings) {
        return [request[@"owner"] isEqual:owner] && [request[@"pending"] boolValue];
    }]];
}
+ (void)finishObservingRequestId:(NSString *)requestID owner:(NSString *)owner {
    for (NSUInteger i = 0; i < requests.count; i++) {
        NSDictionary *request = requests[i];
        if ([request[@"requestId"] isEqual:requestID] && [request[@"owner"] isEqual:owner]) {
            NSMutableDictionary *done = [request mutableCopy]; done[@"pending"] = @NO; requests[i] = done;
        }
    }
}
@end

@implementation RBXSecureConfig
+ (NSDictionary *)identityEditorDraftForRequestID:(NSString *)requestID container:(NSString *)container error:(NSError **)error { return drafts[requestID]; }
@end

// Record public UIAlertAction callbacks while leaving UIKit presentation unchanged.
static char actionCallbackKey;
@interface UIAlertAction (FixtureCallback)
+ (instancetype)fixtureActionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction (FixtureCallback)
+ (instancetype)fixtureActionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self fixtureActionWithTitle:title style:style handler:handler];
    if (handler) objc_setAssociatedObject(action, &actionCallbackKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return action;
}
@end

@interface FixtureEditor : RBXIdentityViewController
@end
@implementation FixtureEditor
- (NSDictionary *)catalog { return fixtureCatalog; }
@end

static void Check(BOOL condition, NSString *message) { checks++; if (!condition) [failures addObject:message]; }
static void Pump(NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void Snapshot(UINavigationController *navigation, NSString *name) {
    UIWindow *window = navigation.view.window;
    [window layoutIfNeeded];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
    NSData *data = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [data writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]] atomically:YES];
}
static UITextField *Field(id editor, NSString *key) { return [editor valueForKey:key]; }
static NSString *Status(id editor) { return [[editor valueForKey:@"statusLabel"] text]; }
static BOOL Enabled(id editor, NSString *key) { return [[editor valueForKey:key] isEnabled]; }
static NSString *Pending(id editor) { return [editor valueForKey:@"pendingRequestId"]; }
static BOOL ContainsLabel(UIView *view, NSString *text) {
    if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text containsString:text]) return YES;
    for (UIView *child in view.subviews) if (ContainsLabel(child, text)) return YES;
    return NO;
}
static UILabel *MatchingLabel(UIView *view,NSString *text) {
    if ([view isKindOfClass:UILabel.class]&&[((UILabel *)view).text containsString:text]) return (id)view;
    for (UIView *child in view.subviews) { UILabel *found=MatchingLabel(child,text); if (found) return found; }
    return nil;
}
static NSDictionary *Draft(NSString *model, NSString *version, BOOL locked) {
    return @{@"productType":model, @"marketingName":model, @"iosVersion":version,
             @"country":@"US", @"locale":@"en_US", @"timezone":@"America/New_York",
             @"carrierCode":@"310:260", @"city":@"New York", @"deviceName":@"Fixture phone",
             @"batteryOffsetPercent":@"0", @"fontSize":@"17", @"idfaPosture":@"random",
             @"serialNumber":[model isEqual:@"iPhone17,3"] ? @"F17TEST001" : @"F14TEST001", @"locked":@(locked),
             @"udid":@"00008110-0011223344556677", @"platformUUID":@"10101010-2020-3030-4040-505050505050",
             @"idfa":@"11111111-2222-3333-4444-555555555555", @"idfv":@"11111111-2222-3333-4444-666666666666",
             @"installId":@"11111111-2222-3333-4444-777777777777", @"externalInstallationId":@"11111111-2222-3333-4444-888888888888",
             @"wifiMac":@"F0:18:98:11:22:33", @"btMac":@"F0:18:98:11:22:34", @"imei1":@"",
             @"mlb":@"ABCD1", @"uniqueChipId":@"18446744073709551614",
             @"syntheticBootEpoch":@"1700000000", @"bootTimeOffsetSeconds":@"3600",
             @"installTimestampMs":@"1690000000000", @"latitude":@"40.7128", @"longitude":@"-74.0060",
             @"security":@{@"strictTiming":@"enabled"}};
}
static void Complete(id editor, NSDictionary *draft, BOOL ok, NSDictionary *details) {
    NSString *requestID = Pending(editor);
    NSDictionary *request = [[requests filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"requestId == %@", requestID]] lastObject];
    if (!requestID) { Check(NO, @"fixture expected an outstanding request"); return; }
    receipts[requestID] = @{@"action":request[@"action"], @"ok":@(ok), @"message":ok ? @"Fixture completed" : @"Fixture rejected", @"details":details ?: @{}};
    if (draft) drafts[requestID] = draft;
    [editor loadResult];
}
static RBXCatalogPickerViewController *Picker(id editor) {
    UIViewController *presented = [editor presentedViewController];
    if (![presented isKindOfClass:UINavigationController.class]) return nil;
    UIViewController *first = ((UINavigationController *)presented).viewControllers.firstObject;
    return [first isKindOfClass:RBXCatalogPickerViewController.class] ? (id)first : nil;
}
static id Select(id editor, NSString *title) {
    Pump(0.6);
    RBXCatalogPickerViewController *picker = Picker(editor);
    if (picker) {
        Check(YES,[@"UIKit presents searchable " stringByAppendingString:title]);
        for (NSInteger section=0;section<[picker numberOfSectionsInTableView:picker.tableView];section++)
            for (NSInteger row=0;row<[picker tableView:picker.tableView numberOfRowsInSection:section];row++) {
                NSIndexPath *path=[NSIndexPath indexPathForRow:row inSection:section];
                UITableViewCell *cell=[picker tableView:picker.tableView cellForRowAtIndexPath:path];
                if ([cell.textLabel.text isEqual:title]) { [picker tableView:picker.tableView didSelectRowAtIndexPath:path]; return cell; }
            }
        Check(NO,[@"missing catalog row: " stringByAppendingString:title]);return nil;
    }
    UIAlertController *sheet = [editor presentedViewController];
    Check([sheet isKindOfClass:UIAlertController.class], [@"UIKit presents " stringByAppendingString:title]);
    for (UIAlertAction *action in sheet.actions) if ([action.title isEqual:title]) {
        void (^handler)(UIAlertAction *) = objc_getAssociatedObject(action, &actionCallbackKey);
        if (handler) handler(action);
        return action;
    }
    Check(NO, [@"missing action: " stringByAppendingString:title]); return nil;
}
static void Dismiss(id editor) {
    [editor dismissViewControllerAnimated:NO completion:nil];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while ([editor presentedViewController] && deadline.timeIntervalSinceNow > 0) Pump(0.05);
    Check(![editor presentedViewController], @"UIKit fixture completes modal dismissal");
    Pump(0.1);
}
static FixtureEditor *Show(UINavigationController *nav, NSString *type, BOOL locked, BOOL simple) {
    FixtureEditor *editor = [[FixtureEditor alloc] initWithContainerRow:@{@"id":NSUUID.UUID.UUIDString, @"name":@"Fixture", @"appType":type} simpleMode:simple];
    [nav setViewControllers:@[editor] animated:NO]; Pump(0.4);
    Check(Pending(editor).length > 0, @"first appearance requests a private draft");
    Check(!Enabled(editor, @"checkButton"), @"empty editor cannot check or save");
    Complete(editor, Draft(@"iPhone14,5", @"17.2", locked), YES, nil);
    return editor;
}

static void RunTests(UINavigationController *nav) {
    fixtureCatalog = @{@"models":@{@"iPhone14,5":@{@"marketingName":@"iPhone 13", @"iosVersions":@[@"17.2"]},
        @"iPhone17,3":@{@"marketingName":@"iPhone 16", @"iosVersions":@[@"18.0", @"18.6"],
            @"hwModelStr":@"D47AP",@"ramBytes":@"8589934592",@"chip":@"A18",
            @"screen":@{@"w":@"1179",@"h":@"2556",@"scale":@"3",@"fps":@"60"}}},
        @"iosBuilds":@{@"18.0":@"22A3354",@"18.6":@"22G86"},
        @"darwinReleases":@{@"18.0":@"24.0.0",@"18.6":@"24.6.0"},
        @"countryLocales":@{@"US":@"en_US",@"CA":@"en_CA"},
        @"countryTimezones":@{@"US":@"America/New_York",@"CA":@"America/Toronto"},
        @"carriers":@{@"US":@[@{@"name":@"T-Mobile",@"mcc":@"310",@"mnc":@"260"},@{@"name":@"AT&T",@"mcc":@"310",@"mnc":@"410"}],@"CA":@[@{@"name":@"Rogers",@"mcc":@"302",@"mnc":@"720"}]},
        @"countryCities":@{@"US":@[@{@"city":@"New York",@"timezone":@"America/New_York",@"lat":@"40.7128",@"lon":@"-74.0060"}],
            @"CA":@[@{@"city":@"Toronto",@"timezone":@"America/Toronto",@"lat":@"43.6532",@"lon":@"-79.3832"}]}};
    {
        FixtureEditor *editor = Show(nav, @"reddit", NO, YES);
        UISegmentedControl *posture = [editor valueForKey:@"idfaControl"];
        UITextField *idfa = [editor valueForKey:@"identifierFields"][@"idfa"];
        posture.selectedSegmentIndex = 1; [posture sendActionsForControlEvents:UIControlEventValueChanged];
        Check([idfa.text isEqual:@"00000000-0000-0000-0000-000000000000"] && !idfa.enabled, @"denied ATT displays the derived zero IDFA read-only");
        [editor checkConsistency];
        Check([requests.lastObject[@"values"][@"choices"][@"idfa"] isEqual:idfa.text] && [idfa.text isEqual:@"00000000-0000-0000-0000-000000000000"], @"Check receives the visible derived zero IDFA");
        Complete(editor, nil, YES, @{@"applied":@NO});
        [editor applyIdentity]; Select(editor, @"Apply");
        Check([requests.lastObject[@"values"][@"choices"][@"idfa"] isEqual:idfa.text] && [idfa.text isEqual:@"00000000-0000-0000-0000-000000000000"] && [requests.lastObject[@"values"][@"choices"][@"mode"] isEqual:@"manual"], @"Save sends the displayed zero IDFA without hidden regeneration");
        Dismiss(editor); Complete(editor, nil, NO, nil);
        posture.selectedSegmentIndex = 0; [posture sendActionsForControlEvents:UIControlEventValueChanged];
        Check(idfa.enabled && [idfa.text isEqual:@"00000000-0000-0000-0000-000000000000"], @"random posture restores editing while keeping its current visible IDFA for review");
        idfa.text = @"11111111-2222-3333-4444-999999999999"; [idfa sendActionsForControlEvents:UIControlEventEditingChanged];
        Check([[editor choices][@"idfa"] isEqual:idfa.text], @"manually edited random IDFA feeds the actual draft");
    }
    {
        FixtureEditor *editor = Show(nav, @"reddit", NO, YES);
        UISegmentedControl *mode = [editor valueForKey:@"modeControl"];
        Check(mode.window != nil && !mode.hidden, @"automatic/manual choice is in the actual visible editor");
        Check([[mode titleForSegmentAtIndex:0] isEqual:@"Automatically fill"] && [[mode titleForSegmentAtIndex:1] isEqual:@"Set manually"], @"editor offers clear automatic and manual choices");
        for (NSString *key in @[@"udid", @"platformUUID"])
            Check([[[editor valueForKey:@"identifierFields"] objectForKey:key] window] != nil, [@"simple editor always exposes identifier: " stringByAppendingString:key]);
        UISwitch *attest = [editor valueForKey:@"securitySwitches"][@"appAttest"];
        attest.on = YES; [attest sendActionsForControlEvents:UIControlEventValueChanged];
        NSDictionary *before = [editor choices]; NSUInteger count = requests.count;
        mode.selectedSegmentIndex = 0; [mode sendActionsForControlEvents:UIControlEventValueChanged];
        Check(requests.count == count && [[editor choices] isEqual:before], @"choosing automatic mode does not change or generate the loaded draft");
        UIButton *fill = [editor valueForKey:@"randomButton"];
        Check([fill.currentTitle isEqual:@"Fill automatically"] && !fill.hidden, @"automatic mode exposes an explicit fill action");
        [fill sendActionsForControlEvents:UIControlEventTouchUpInside];
        Check([requests.lastObject[@"action"] isEqual:@"randomizeIdentityEditor"] && [requests.lastObject[@"values"][@"selection"] isEqual:@{@"automatic":@YES}], @"automatic fill requests full generation without selected-model constraints");
        Check(!Enabled(editor, @"applyButton") && !mode.enabled, @"automatic generation disables Save and duplicate input while pending");
        [fill sendActionsForControlEvents:UIControlEventTouchUpInside];
        Check(requests.count == count + 1, @"automatic fill creates only one pending request");
        NSMutableDictionary *automatic = [Draft(@"iPhone17,3", @"18.6", NO) mutableCopy];
        [automatic addEntriesFromDictionary:@{@"country":@"CA", @"locale":@"en_CA", @"timezone":@"America/Toronto", @"carrierCode":@"302-720", @"city":@"Toronto",
            @"udid":@"00008140-0011223344556677", @"platformUUID":@"BA6DD7A4-7184-4CBC-AD84-BA5F678DF6E1",
            @"automaticRegion":@{@"country":@"CA", @"timezone":@"America/Toronto", @"city":@"Toronto", @"proxySource":@"selected"}}];
        Complete(editor, automatic, YES, nil);
        NSDictionary *generated = [editor choices];
        for (NSString *key in @[@"productType", @"iosVersion", @"udid", @"platformUUID", @"country", @"locale", @"timezone", @"carrierCode", @"city", @"mlb", @"uniqueChipId", @"syntheticBootEpoch", @"bootTimeOffsetSeconds", @"installTimestampMs", @"latitude", @"longitude"])
            Check([generated[key] isEqual:automatic[key]], [@"automatic result is displayed for review: " stringByAppendingString:key]);
        Check([generated[@"security"] isEqual:before[@"security"]], @"automatic fill preserves even unsaved compatibility-policy choices");
        Check(mode.selectedSegmentIndex == 1 && [generated[@"mode"] isEqual:@"manual"] && [[editor valueForKey:@"advancedStack"] superview] != nil, @"automatic success opens every manual field and uses the displayed draft");
        Check(requests.count == count + 1 && !Enabled(editor, @"applyButton") && [Status(editor) containsString:@"Automatic draft"], @"automatic fill returns an unsaved draft requiring review and Check");
        [editor checkConsistency];
        Check([requests.lastObject[@"values"][@"choices"] isEqual:generated], @"Check receives the complete automatic draft unchanged");
        Complete(editor, nil, YES, @{@"applied":@NO});
        mode.selectedSegmentIndex = 0; [mode sendActionsForControlEvents:UIControlEventValueChanged];
        Check([[editor choices] isEqual:generated] && Enabled(editor, @"applyButton"), @"changing presentation mode cannot invalidate or rerandomize checked values");
        [editor applyIdentity]; Select(editor, @"Apply");
        Check([requests.lastObject[@"action"] isEqual:@"applyIdentity"] && [requests.lastObject[@"values"][@"choices"] isEqual:generated], @"Save uses exact reviewed automatic values in manual mode");
        Dismiss(editor); Complete(editor, nil, NO, nil);

        before = [editor choices]; count = requests.count;
        mode.selectedSegmentIndex = 1; [mode sendActionsForControlEvents:UIControlEventValueChanged];
        Check([[editor choices] isEqual:before] && requests.count == count, @"Set manually preserves all existing draft values and sends no request");
        mode.selectedSegmentIndex = 0; [mode sendActionsForControlEvents:UIControlEventValueChanged];
        before = [editor choices];
        [fill sendActionsForControlEvents:UIControlEventTouchUpInside]; Complete(editor, nil, NO, nil);
        Check([[editor choices] isEqual:before] && [Status(editor) containsString:@"draft kept"], [NSString stringWithFormat:@"failed automatic generation keeps the complete loaded draft with a clear error (same=%d, status=%@, pending=%@)", [[editor choices] isEqual:before], Status(editor), Pending(editor)]);
        rejectSend = YES; [fill sendActionsForControlEvents:UIControlEventTouchUpInside]; rejectSend = NO;
        Check([[editor choices] isEqual:before] && !Pending(editor).length && [Status(editor) containsString:@"could not be sent"], [NSString stringWithFormat:@"automatic send failure keeps the draft editable and unsaved (same=%d, status=%@, pending=%@)", [[editor choices] isEqual:before], Status(editor), Pending(editor)]);

        NSMutableDictionary *incomplete = [Draft(@"iPhone14,5", @"17.2", NO) mutableCopy];
        [incomplete removeObjectForKey:@"udid"]; [incomplete removeObjectForKey:@"platformUUID"];
        [editor reloadIdentity]; Complete(editor, incomplete, YES, nil);
        Check(ContainsLabel(editor.view, @"Missing required identifiers") && ContainsLabel(editor.view, @"UDID") && ContainsLabel(editor.view, @"Platform UUID"), [NSString stringWithFormat:@"incomplete older drafts explicitly identify missing required identifiers (status=%@, pending=%@)", Status(editor), Pending(editor)]);
        Check(Field(editor, @"productTypeField").enabled && [[[editor valueForKey:@"identifierFields"] objectForKey:@"udid"] isEnabled], [NSString stringWithFormat:@"incomplete draft stays manually editable (pending=%@)", Pending(editor)]);
        [editor checkConsistency]; Complete(editor, nil, YES, @{@"applied":@NO});
        Check(!Enabled(editor, @"applyButton"), @"missing displayed required identifiers cannot appear ready to Save");
        mode.selectedSegmentIndex = 0; [mode sendActionsForControlEvents:UIControlEventValueChanged];
        [fill sendActionsForControlEvents:UIControlEventTouchUpInside]; Complete(editor, automatic, YES, nil);
        Check(!ContainsLabel(editor.view, @"Missing required identifiers") && [[editor choices][@"udid"] isEqual:automatic[@"udid"]] && [[editor choices][@"platformUUID"] isEqual:automatic[@"platformUUID"]], @"automatic generation repairs visibly missing UUID and UDID fields");
        Check(ContainsLabel(editor.view, @"Required identifiers are filled"), @"filled identifiers have explicit status without treating a blank generic IMEI as missing");
    }
    FixtureEditor *editor = Show(nav, @"reddit", NO, NO);
    Check(Enabled(editor, @"checkButton") && !Enabled(editor, @"applyButton"), @"loaded draft requires a consistency check");
    NSDictionary *beforePicker = [editor choices]; NSUInteger requestsBeforePicker = requests.count;
    [editor chooseModel]; Pump(.4);
    RBXCatalogPickerViewController *modelPicker = Picker(editor);
    Snapshot(nav,@"01-model-picker");
    Check(modelPicker.options.count==2 && [modelPicker.selectedValue isEqual:@"iPhone14,5"],@"Searchable model picker marks the current supported model");
    modelPicker.search.searchBar.text=@"iphone17,3";
    [modelPicker updateSearchResultsForSearchController:modelPicker.search];
    Check([modelPicker tableView:modelPicker.tableView numberOfRowsInSection:0]==1 &&
        [[[modelPicker tableView:modelPicker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]] textLabel].text isEqual:@"iPhone 16"],@"Model search matches hardware code as well as display name");
    modelPicker.search.searchBar.text=@"  IPHONE 13  ";
    [modelPicker updateSearchResultsForSearchController:modelPicker.search];
    Check([modelPicker tableView:modelPicker.tableView numberOfRowsInSection:0]==1 &&
        [modelPicker tableView:modelPicker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].accessoryType==UITableViewCellAccessoryCheckmark,@"Search preserves current-selection checkmark and ignores case and edge whitespace");
    modelPicker.search.searchBar.text=@"No matching phone";
    [modelPicker updateSearchResultsForSearchController:modelPicker.search];
    Check([modelPicker tableView:modelPicker.tableView numberOfRowsInSection:0]==0 &&
        [[modelPicker tableView:modelPicker.tableView titleForFooterInSection:0] containsString:@"No matching choices"],@"Empty catalog search has an honest recoverable state");
    Check(requests.count==requestsBeforePicker && [[editor choices] isEqual:beforePicker],@"Searching cannot change identity or enqueue a generator");
    UIBarButtonItem *cancel = modelPicker.navigationItem.leftBarButtonItem;
    [UIApplication.sharedApplication sendAction:cancel.action to:cancel.target from:cancel forEvent:nil];
    NSDate *cancelDeadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (editor.presentedViewController && cancelDeadline.timeIntervalSinceNow > 0) Pump(.05);
    Check(!editor.presentedViewController && requests.count==requestsBeforePicker && [[editor choices] isEqual:beforePicker],
        [NSString stringWithFormat:@"Cancel dismisses the picker and preserves the entire draft (modal=%@, requests=%lu/%lu, same=%d)",editor.presentedViewController,(unsigned long)requests.count,(unsigned long)requestsBeforePicker,[[editor choices] isEqual:beforePicker]]);
    [editor chooseModel]; Select(editor, @"iPhone 16"); Pump(0.05);
    Check([requests.lastObject[@"action"] isEqual:@"randomizeIdentityEditor"], @"model choice prepares a matching draft");
    Check([requests.lastObject[@"values"][@"selection"][@"productType"] isEqual:@"iPhone17,3"], @"selected model reaches request selection");
    Check([requests.lastObject[@"values"][@"selection"][@"iosVersion"] isEqual:@"18.6"], @"model change defaults to newest compatible iOS");
    Check([Status(editor) containsString:@"Preparing random draft"], @"picker keeps pending status instead of overwriting it");
    Complete(editor, Draft(@"iPhone17,3", @"18.6", NO), YES, nil);
    Check(Pending(editor).length > 0, @"completed receipt is deferred while the picker is presented");
    Dismiss(editor); Pump(0.6);
    Check(!Pending(editor).length, @"fast receipt resumes automatically after picker dismissal");
    Check([[[editor valueForKey:@"identifierFields"] objectForKey:@"serialNumber"] text] &&
        [[[[editor valueForKey:@"identifierFields"] objectForKey:@"serialNumber"] text] isEqual:@"F17TEST001"], @"model change installs its matching private identifiers");
    if (Pending(editor).length) [editor loadResult]; // Let independent checks run on an unfixed editor.

    [editor chooseIOS]; Pump(0.3);
    RBXCatalogPickerViewController *iosSheet = Picker(editor);
    Snapshot(nav,@"02-ios-picker");
    Check(iosSheet.options.count == 2 && [iosSheet.options.firstObject[@"title"] isEqual:@"18.6"] &&
        iosSheet.navigationItem.leftBarButtonItem != nil, @"iOS picker exposes all compatible versions newest first and Cancel");
    Check([iosSheet.selectedValue isEqual:@"18.6"] && [iosSheet.options.firstObject[@"subtitle"] containsString:@"22G86"],@"iOS picker identifies the current value and its catalog build");
    Select(editor, @"18.0"); Dismiss(editor);
    Check([[editor choices][@"iosVersion"] isEqual:@"18.0"], @"iOS picker changes the actual choices");
    NSString *derived = [[editor valueForKey:@"derivedIdentityLabel"] text];
    for (NSString *value in @[@"D47AP",@"8589934592",@"1179",@"2556",@"22A3354",@"24.0.0"])
        Check([derived containsString:value], @"derived hardware/software display follows the reviewed tuple");
    Field(editor,@"countryField").text=@"CA"; Field(editor,@"cityField").text=@"Toronto";
    [editor fillCoordinatesForSelectedCity]; [editor choicesChanged];
    Check([[editor choices][@"latitude"] isEqual:@"43.6532"] && [[editor choices][@"longitude"] isEqual:@"-79.3832"] &&
        [[editor choices][@"timezone"] isEqual:@"America/Toronto"],@"city selection updates both displayed coordinates and timezone");

    [editor chooseCarrier]; Pump(.3);
    RBXCatalogPickerViewController *carrierPicker=Picker(editor);
    Snapshot(nav,@"03-carrier-picker");
    Check(carrierPicker.options.count==1 && [carrierPicker.options.firstObject[@"value"] isEqual:@"302-720"] &&
        [[carrierPicker tableView:carrierPicker.tableView titleForHeaderInSection:0] containsString:@"CA"],@"Carrier picker is grouped and restricted to the selected country");
    Select(editor,@"Rogers"); Dismiss(editor);
    Check([Field(editor,@"carrierField").text isEqual:@"302-720"],@"Carrier selection updates the actual draft code");
    [editor chooseCity]; Pump(.3);
    RBXCatalogPickerViewController *cityPicker=Picker(editor);
    Check(cityPicker.options.count==1 && [cityPicker.options.firstObject[@"subtitle"] isEqual:@"America/Toronto"],@"City picker stays country-scoped and exposes timezone");
    Select(editor,@"Toronto"); Dismiss(editor);
    Check([[editor choices][@"latitude"] isEqual:@"43.6532"] && [[editor choices][@"longitude"] isEqual:@"-79.3832"],@"City picker applies coherent catalog coordinates");
    [editor chooseLanguage]; Pump(.3);
    RBXCatalogPickerViewController *languagePicker=Picker(editor);
    Check(languagePicker.options.count==1 && [languagePicker.options.firstObject[@"value"] isEqual:@"en_CA"],@"Language picker exposes only the country's supported regional locale");
    Dismiss(editor);
    [editor chooseRegion]; Pump(.3);
    RBXCatalogPickerViewController *regionPicker=Picker(editor);
    Snapshot(nav,@"04-country-picker");
    Check(regionPicker.options.count==2,@"Country picker enumerates the supported catalog instead of inventing countries");
    regionPicker.search.searchBar.text=@"US";[regionPicker updateSearchResultsForSearchController:regionPicker.search];
    Check([regionPicker tableView:regionPicker.tableView numberOfRowsInSection:0]==1,@"Country search also matches ISO code");
    beforePicker=[editor choices];requestsBeforePicker=requests.count;
    Dismiss(editor);
    Check([[editor choices] isEqual:beforePicker] && requests.count==requestsBeforePicker,@"Dismissing a regional picker never changes identity or proxy state");

    // Exercise every editable identity field, segmented preference and compatibility switch.
    NSDictionary *fieldValues = @{@"countryField":@"ca", @"localeField":@"en_CA", @"timezoneField":@"America/Toronto",
        @"carrierField":@"302:720", @"cityField":@"Toronto", @"deviceNameField":@"Chosen phone", @"batteryField":@"3"};
    for (NSString *key in fieldValues) { Field(editor, key).text = fieldValues[key]; [Field(editor, key) sendActionsForControlEvents:UIControlEventEditingChanged]; }
    UISegmentedControl *idfa = [editor valueForKey:@"idfaControl"]; idfa.selectedSegmentIndex = 1; [idfa sendActionsForControlEvents:UIControlEventValueChanged];
    UISegmentedControl *font = [editor valueForKey:@"fontControl"]; font.selectedSegmentIndex = 2; [font sendActionsForControlEvents:UIControlEventValueChanged];
    for (UISwitch *toggle in [[editor valueForKey:@"securitySwitches"] allValues]) { toggle.on = !toggle.on; [toggle sendActionsForControlEvents:UIControlEventValueChanged]; }
    for (UITextField *field in [[editor valueForKey:@"identifierFields"] allValues]) if (field.enabled) { field.text = @"edited-identifier"; [field sendActionsForControlEvents:UIControlEventEditingChanged]; }
    NSDictionary *chosen = [editor choices];
    NSDictionary *expected = @{@"productType":@"iPhone17,3", @"iosVersion":@"18.0", @"country":@"CA", @"locale":@"en_CA",
        @"timezone":@"America/Toronto", @"carrierCode":@"302:720", @"city":@"Toronto", @"deviceName":@"Chosen phone",
        @"batteryOffsetPercent":@"3", @"fontSize":@"19", @"idfaPosture":@"zeroWithATTDenied"};
    for (NSString *key in expected) Check([chosen[key] isEqual:expected[key]], [@"edited value reaches choices: " stringByAppendingString:key]);
    for (NSString *key in [editor valueForKey:@"identifierFields"]) Check([chosen[key] isEqual:[key isEqual:@"idfa"] ? @"00000000-0000-0000-0000-000000000000" : @"edited-identifier"], [@"expert identifier reaches choices: " stringByAppendingString:key]);
    for (NSString *key in [editor valueForKey:@"securitySwitches"]) Check([chosen[@"security"][key] boolValue] == ![key isEqual:@"strictTiming"], [@"policy switch reaches choices: " stringByAppendingString:key]);
    [editor checkConsistency];
    Check([requests.lastObject[@"values"][@"choices"] isEqual:chosen], @"Check receives all chosen fields and policies unchanged");
    Check(!Enabled(editor, @"checkButton") && !Enabled(editor, @"randomButton") && !Field(editor, @"deviceNameField").enabled, @"pending Check disables edits and repeated actions");
    Check(![[[editor valueForKey:@"securitySwitches"] objectForKey:@"appAttest"] isEnabled] && !Enabled(editor, @"idfaControl") && !Enabled(editor, @"fontControl"), @"pending Check freezes policy and segmented preferences too");
    Complete(editor, nil, YES, @{@"applied":@NO});
    Check(Enabled(editor, @"checkButton") && Field(editor, @"deviceNameField").enabled && Enabled(editor, @"applyButton"), @"successful Check restores controls and authorizes exact choices");
    [editor applyIdentity]; Select(editor, @"Apply");
    Check([requests.lastObject[@"action"] isEqual:@"applyIdentity"] && [requests.lastObject[@"values"][@"choices"] isEqual:chosen], @"Save sends exactly the checked choices");
    Check(!Field(editor, @"deviceNameField").enabled, @"pending Save disables editable controls");
    Dismiss(editor); Complete(editor, nil, NO, nil);
    Check(Field(editor, @"deviceNameField").enabled && !Enabled(editor, @"applyButton"), @"failed Save restores editing but requires another Check");

    [editor checkConsistency]; Complete(editor, nil, YES, @{@"applied":@NO});
    [editor applyIdentity]; Pump(0.3);
    NSUInteger count = requests.count;
    Field(editor, @"deviceNameField").text = @"changed after review"; [editor choicesChanged];
    Select(editor, @"Apply");
    Check(requests.count == count, @"confirmation cannot submit values changed after Check");
    Dismiss(editor); if (Pending(editor).length) Complete(editor, nil, NO, nil);

    [editor saveSentinelSettings];
    Check(!Enabled(editor, @"sentinelSaveButton") && !Enabled(editor, @"sentinelSwitch") && !Enabled(editor, @"checkButton"), @"sentinel save prevents conflicting editor actions");
    Complete(editor, nil, YES, nil);
    Check(Enabled(editor, @"sentinelSaveButton") && Enabled(editor, @"sentinelSwitch") && Enabled(editor, @"checkButton"), @"sentinel receipt restores controls");
    [editor saveSentinelSettings]; Complete(editor, nil, NO, nil);
    Check(Enabled(editor, @"sentinelSaveButton") && [Status(editor) isEqual:@"Fixture rejected"], @"failed sentinel save restores controls and preserves its error");

    rejectSend = YES; [editor chooseModel]; Select(editor, @"iPhone 13"); Pump(0.05);
    Check([Status(editor) containsString:@"could not be sent"], @"failed draft request remains visible after picker callback");
    Dismiss(editor); rejectSend = NO;

    rejectSend = YES; [editor checkConsistency];
    Check(!Pending(editor).length && Enabled(editor, @"checkButton") && !Enabled(editor, @"applyButton") && [Status(editor) containsString:@"could not be sent"], @"failed Check send leaves an editable draft and visible error");
    rejectSend = NO;
    [editor reloadIdentity]; Complete(editor, nil, NO, nil);
    Check([Status(editor) containsString:@"Could not load identity"] && !Enabled(editor, @"applyButton"), @"failed reload cannot retain an old Save authorization");

    // An outstanding request must not update another screen after navigation.
    editor = Show(nav, @"reddit", NO, NO);
    [editor checkConsistency];
    [nav pushViewController:[UIViewController new] animated:NO]; Pump(0.4);
    Check(nav.topViewController != editor, @"fixture navigates away with a request pending");
    Complete(editor, nil, YES, @{@"applied":@NO});
    Check(Pending(editor).length > 0, @"a receipt is retained after leaving the editor");
    [nav popViewControllerAnimated:NO]; Pump(0.5);
    Check(!Pending(editor).length && Enabled(editor, @"applyButton"), @"returning to the editor resumes the retained Check result");

    [editor chooseModel]; Pump(0.3);
    [editor setValue:Draft(@"iPhone14,5", @"17.2", YES) forKey:@"identity"];
    count = requests.count; Select(editor, @"iPhone 16");
    Check(requests.count == count && [Field(editor, @"productTypeField").text isEqual:@"iPhone14,5"], @"stale picker cannot modify an identity locked after presentation");
    Dismiss(editor);

    editor = Show(nav,@"reddit",NO,NO);
    [editor chooseModel]; Pump(.3);
    [editor checkConsistency];
    beforePicker=[editor choices]; count=requests.count;
    Select(editor,@"iPhone 16");
    Check(requests.count==count && [[editor choices] isEqual:beforePicker],@"Picker opened before a pending request cannot change its in-flight draft");
    Dismiss(editor); Complete(editor,nil,NO,nil);

    editor = Show(nav, @"reddit", YES, YES);
    Check(!Enabled(editor, @"randomButton") && !Field(editor, @"productTypeField").enabled && !Field(editor, @"iosVersionField").enabled, @"first-use freeze preserves model and iOS lock");
    Check([Status(editor).lowercaseString containsString:@"locked"] && [Status(editor).lowercaseString containsString:@"new container"], @"locked editor explains how to choose another model or iOS");
    Check(Enabled(editor, @"checkButton") && [[[editor valueForKey:@"securitySwitches"] objectForKey:@"appAttest"] isEnabled], @"locked identity keeps compatibility policies editable");
    count = requests.count; [editor randomFill]; [editor chooseModel];
    Check(requests.count == count && !editor.presentedViewController, @"frozen model has no picker or random-fill mutation");
    Check([[editor choices][@"securityOnly"] boolValue], @"locked Check carries security-only contract");
    if (![[editor valueForKey:@"advancedStack"] superview]) [editor toggleAdvancedGroups];
    Check([[editor valueForKey:@"advancedStack"] superview] != nil, @"simple mode expands editable policy groups");
    NSMutableDictionary *lockedDraft = [Draft(@"iPhone14,5", @"17.2", YES) mutableCopy];
    [lockedDraft removeObjectForKey:@"udid"];
    [editor reloadIdentity]; Complete(editor, lockedDraft, YES, nil);
    Check(ContainsLabel(editor.view, @"Missing required identifiers") && ContainsLabel(editor.view, @"This identity is locked"), @"incomplete frozen draft explains reload/new-container recovery");
    UISegmentedControl *lockedPosture = [editor valueForKey:@"idfaControl"];
    lockedPosture.selectedSegmentIndex = 1; [lockedPosture sendActionsForControlEvents:UIControlEventValueChanged];
    Check(lockedPosture.selectedSegmentIndex == 0 && [[editor choices][@"idfa"] isEqual:lockedDraft[@"idfa"]], @"frozen identity cannot change its saved IDFA posture or value");
    [editor checkConsistency]; Complete(editor, nil, YES, @{@"applied":@NO});
    Check(Enabled(editor, @"applyButton") && [[editor choices][@"securityOnly"] boolValue], @"missing displayed identifiers do not block validated policy-only saves on a frozen profile");

    editor = Show(nav, @"facebook", NO, NO);
    Check([requests.lastObject[@"appType"] isEqual:@"facebook"] && [requests.lastObject[@"owner"] containsString:@"facebook"], @"Facebook editor private requests retain explicit owner scope");
    Check([editor valueForKey:@"fontControl"] == nil && [[editor valueForKey:@"identifierFields"] objectForKey:@"installId"] == nil, @"Facebook omits Reddit-only editable controls");
    [editor checkConsistency]; Complete(editor, nil, NO, nil);
    Check([Status(editor) hasPrefix:@"FAIL"] && !Enabled(editor, @"applyButton"), @"inactive or rejected Facebook requests show failure without authorizing Save");

    // Creation editor uses the same UIKit form but cannot mutate a saved clone.
    FixtureEditor *prepared = [[FixtureEditor alloc] initWithContainerRow:@{@"id":@"draft-fixture",@"name":@"Preview",@"appType":@"reddit"} simpleMode:YES];
    prepared.creationDraftToken = @"8153BF45-673A-4D40-BFD4-67D6C647D70F";
    prepared.creationDraftRevision = @1;
    [nav setViewControllers:@[prepared] animated:NO]; Pump(0.4);
    Check([requests.lastObject[@"values"][@"creationDraftToken"] isEqual:prepared.creationDraftToken] &&
        [requests.lastObject[@"values"][@"creationDraftRevision"] isEqual:@1], @"Creation editor loads only its exact daemon-owned draft");
    Check([requests.lastObject[@"owner"] hasPrefix:@"creation-identity:"],@"Unsaved editor request owner is separate from existing container editor");
    NSDictionary *draftResult = @{@"creationDraftToken":prepared.creationDraftToken,@"creationDraftRevision":@1};
    Complete(prepared,Draft(@"iPhone14,5",@"17.2",NO),YES,draftResult);
    Check([prepared valueForKey:@"sentinelSaveButton"] == nil,@"Creation preview cannot configure a nonexistent clone's sentinel");
    [prepared randomFill];
    Check([requests.lastObject[@"values"][@"creationDraftRevision"] isEqual:@1],@"Creation random fill is revision-bound");
    Complete(prepared,Draft(@"iPhone14,5",@"17.2",NO),YES,@{@"creationDraftToken":prepared.creationDraftToken,@"creationDraftRevision":@2});
    Check([prepared.creationDraftRevision isEqual:@2],@"Randomized draft adopts authoritative new revision");
    [prepared checkConsistency];
    Check([requests.lastObject[@"values"][@"creationDraftRevision"] isEqual:@2],@"Consistency check addresses updated unsaved revision");
    Complete(prepared,nil,YES,@{@"applied":@NO,@"creationDraftToken":prepared.creationDraftToken,@"creationDraftRevision":@2});
    [prepared applyIdentity]; Pump(0.3);
    Check([((UIAlertController *)prepared.presentedViewController).message containsString:@"only the preview"],@"Creation save explains no clone is rebuilt");
    Select(prepared,@"Apply");
    Check([requests.lastObject[@"values"][@"creationDraftToken"] isEqual:prepared.creationDraftToken],@"Save remains in unsaved draft namespace");
    Dismiss(prepared);
    Complete(prepared,nil,YES,@{@"applied":@YES,@"creationDraftToken":prepared.creationDraftToken,@"creationDraftRevision":@3});
    Check([prepared.creationDraftRevision isEqual:@3],@"Save updates authoritative revision");
    Pump(0.3);
    Check([((UIAlertController *)prepared.presentedViewController).message containsString:@"No container exists yet"],@"Saved preview asks for explicit Create later");
    Dismiss(prepared);

    FixtureEditor *empty = [[FixtureEditor alloc] initWithContainerRow:@{@"id":NSUUID.UUID.UUIDString, @"name":@"Missing private draft"}];
    [nav setViewControllers:@[empty] animated:NO]; Pump(0.4);
    Complete(empty, nil, YES, nil);
    Check(!Enabled(empty, @"checkButton") && !Enabled(empty, @"randomButton") && !Enabled(empty, @"applyButton") && [Status(empty) containsString:@"Could not load identity"], @"a successful receipt without its private draft cannot enable identity editing");
    count = requests.count; [empty checkConsistency]; [empty randomFill]; [empty applyIdentity];
    Check(requests.count == count, @"an empty form never sends Check, Save or Random fill");

    Check([RBXIdentityFieldHelp(@"batteryOffsetPercent") containsString:@"synthetic"], @"battery help describes synthetic level");
    Check([RBXIdentityFieldHelp(@"localNetworking") containsString:@"loopback"], @"local-network help describes actual loopback exception");

    FixtureEditor *mapEditor=Show(nav,@"reddit",NO,YES);
    NSDictionary *originalMapChoices=[mapEditor choices]; NSUInteger mapRequestCount=requests.count;
    [mapEditor chooseLocationMap]; Pump(.4);
    RBXLocationPickerViewController *map=(id)((UINavigationController *)mapEditor.presentedViewController).topViewController;
    Check([map isKindOfClass:RBXLocationPickerViewController.class],@"Location button opens actual MapKit editor");
    MKMapView *mapView=[map valueForKey:@"map"];
    Check([mapView isKindOfClass:MKMapView.class]&&!mapView.showsUserLocation,@"Map shows a real interactive pin without physical GPS");
    Check(mapView.annotations.count==1&&Enabled(map,@"applyButton"),@"Saved coherent coordinates populate map and draft action");
    Check(map.navigationController.traitCollection.userInterfaceStyle==UIUserInterfaceStyleDark,@"Map modal navigation remains dark even over a light parent");
    Snapshot(nav,@"05-location-map");
    if (getenv("RBX_TEST_KEYBOARD")) {
    UITextField *keyboardSearch=[map valueForKey:@"searchField"];
    __block CGRect shownKeyboard=CGRectZero;
    id keyboardObserver=[NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        shownKeyboard=[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    }];
    [keyboardSearch becomeFirstResponder]; Pump(1.0); [map.view layoutIfNeeded];
    CGFloat keyboardTop=CGRectGetMinY(map.view.keyboardLayoutGuide.layoutFrame);
    CGRect searchFrame=[keyboardSearch convertRect:keyboardSearch.bounds toView:map.view];
    Check(keyboardSearch.isFirstResponder&&shownKeyboard.size.height>100&&map.view.keyboardLayoutGuide.layoutFrame.size.height>100,@"Coordinate keyboard actually appears on the small-screen simulator");
    Check(CGRectGetMinY(searchFrame)>=map.view.safeAreaInsets.top&&CGRectGetMaxY(searchFrame)<=keyboardTop&&searchFrame.size.height>=40,@"Coordinate input remains visible above the real keyboard");
    UILabel *keyboardStatus=[map valueForKey:@"statusLabel"];
    CGSize requiredStatus=[keyboardStatus sizeThatFits:CGSizeMake(keyboardStatus.bounds.size.width,CGFLOAT_MAX)];
    Check(keyboardStatus.bounds.size.height+.5>=requiredStatus.height,@"Keyboard does not compress or truncate location validation text");
    UIButton *keyboardApply=[map valueForKey:@"applyButton"];
    CGRect applyFrame=[keyboardApply convertRect:keyboardApply.bounds toView:map.view];
    Check(keyboardApply.bounds.size.height>=44&&CGRectGetMinY(applyFrame)>=CGRectGetMaxY([keyboardStatus convertRect:keyboardStatus.bounds toView:map.view]),@"Keyboard retains a non-overlapping usable draft action");
    UILabel *keyboardNote=MatchingLabel(map.view,@"Apple Maps uses SocialBox");
    Check(keyboardNote.bounds.size.height+.5>=[keyboardNote sizeThatFits:CGSizeMake(keyboardNote.bounds.size.width,CGFLOAT_MAX)].height,@"Keyboard does not truncate the proxy-routing explanation");
    UIScrollView *keyboardScroll=[map valueForKey:@"contentScroll"];
    Check(keyboardScroll.contentSize.height>keyboardScroll.bounds.size.height&&mapView.bounds.size.height>=160,@"Keyboard retains the map and makes the complete form scrollable");
    [keyboardScroll scrollRectToVisible:[keyboardApply convertRect:keyboardApply.bounds toView:keyboardScroll] animated:NO];
    [map.view layoutIfNeeded];
    CGRect visibleApply=[keyboardApply convertRect:keyboardApply.bounds toView:map.view];
    Check(CGRectGetMinY(visibleApply)>=map.view.safeAreaInsets.top&&CGRectGetMaxY(visibleApply)<=keyboardTop+.5,@"Draft action can be scrolled fully above the visible keyboard");
    [keyboardScroll scrollRectToVisible:[keyboardSearch convertRect:keyboardSearch.bounds toView:keyboardScroll] animated:NO];
    [map.view layoutIfNeeded];
    Snapshot(nav,@"05a-location-keyboard");
    NSString *keyboardDirectory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [@"ready" writeToFile:[keyboardDirectory stringByAppendingPathComponent:@"keyboard-ready"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDate *keyboardDeadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (![NSFileManager.defaultManager fileExistsAtPath:[keyboardDirectory stringByAppendingPathComponent:@"keyboard-captured"]]&&keyboardDeadline.timeIntervalSinceNow>0) Pump(.05);
    [keyboardSearch resignFirstResponder]; Pump(.4);
    [NSNotificationCenter.defaultCenter removeObserver:keyboardObserver];
    }
    [map mapViewWillStartLoadingMap:mapView];
    Check([[[map valueForKey:@"mapStatusLabel"] text] containsString:@"Loading"],@"Tile service starts visibly pending rather than claiming readiness");
    [map mapViewDidFinishRenderingMap:mapView fullyRendered:NO];
    Check([[[map valueForKey:@"mapStatusLabel"] text] containsString:@"Loading"],@"Partial map render never marks tile service ready");
    [map mapViewDidFailLoadingMap:mapView withError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
    Check([[[map valueForKey:@"mapStatusLabel"] text] containsString:@"unavailable"]&&Enabled(map,@"applyButton"),@"Tile failure has an explicit offline message and preserves coordinate editor");
    Snapshot(nav,@"05b-location-tile-failure");
    [map mapViewDidFinishRenderingMap:mapView fullyRendered:YES];
    Check([[[map valueForKey:@"mapStatusLabel"] text] containsString:@"loaded"],@"Map-ready indicator requires fully rendered delegate callback (simulated service response only)");
    [map selectLatitude:@"40.7200" longitude:@"-74.0000"];
    Check([[mapEditor choices] isEqual:originalMapChoices]&&requests.count==mapRequestCount,@"Moving a pin does not mutate identity or send IPC");
    [map cancel]; Dismiss(mapEditor);
    Check([[mapEditor choices] isEqual:originalMapChoices],@"Map cancel preserves complete original identity");
    [mapEditor chooseLocationMap]; Pump(.35);
    map=(id)((UINavigationController *)mapEditor.presentedViewController).topViewController;
    [map selectLatitude:@"0" longitude:@"0"];
    Check(!Enabled(map,@"applyButton")&&[Status(map) containsString:@"Outside"],@"Unsupported map pin cannot be applied");
    [map applyLocation]; Check([[mapEditor choices] isEqual:originalMapChoices],@"Disabled apply handler also rejects invalid coordinates");
    UITextField *search=[map valueForKey:@"searchField"]; search.text=@"40.7200, -74.0000";
    [map textFieldShouldReturn:search];
    Check(Enabled(map,@"applyButton"),@"Coordinate input updates validated map pin");
    search.text=@"NaN, -74"; [map textFieldShouldReturn:search];
    Check(!Enabled(map,@"applyButton")&&[Status(map) containsString:@"Enter valid"],@"Malformed coordinate input reports validation directly rather than opening city search");
    search.text=@"40.7200, -74.0000"; [map textFieldShouldReturn:search];
    [map applyLocation]; Dismiss(mapEditor);
    NSDictionary *mapChoices=[mapEditor choices];
    Check([mapChoices[@"latitude"] isEqual:@"40.720000"]&&[mapChoices[@"longitude"] isEqual:@"-74.000000"]&&
        [mapChoices[@"city"] isEqual:@"New York"]&&[mapChoices[@"timezone"] isEqual:@"America/New_York"],@"Explicit Use in draft updates coherent coordinates/city/timezone");
    Check([mapChoices[@"idfv"] isEqual:originalMapChoices[@"idfv"]]&&requests.count==mapRequestCount&&!Enabled(mapEditor,@"applyButton"),@"Map retains identifiers and requires existing Check/Save flow");
    [mapEditor chooseLocationMap]; Pump(.35);
    map=(id)((UINavigationController *)mapEditor.presentedViewController).topViewController;
    search=[map valueForKey:@"searchField"]; search.text=@"New York"; [map textFieldShouldReturn:search]; Pump(.4);
    RBXCatalogPickerViewController *cities=(id)((UINavigationController *)map.presentedViewController).topViewController;
    Check([cities isKindOfClass:RBXCatalogPickerViewController.class]&&cities.options.count==1&&
        [cities.options.firstObject[@"group"] isEqual:@"US"],@"Map city search is local and country-scoped");
    Select(map,@"New York"); Dismiss(map);
    Check([[mapEditor choices] isEqual:mapChoices],@"City search only changes map preview until explicitly used");
    NSMutableDictionary *lockedIdentity=[[mapEditor valueForKey:@"identity"] mutableCopy]; lockedIdentity[@"locked"]=@YES;
    [mapEditor setValue:lockedIdentity forKey:@"identity"];
    NSDictionary *choicesAfterLock=[mapEditor choices];
    [map applyLocation]; Dismiss(mapEditor);
    Check([[mapEditor choices] isEqual:choicesAfterLock]&&[Status(mapEditor) containsString:@"changed while"],@"Queued map callback cannot mutate an identity locked after presentation");
    [mapEditor chooseLocationMap]; Pump(.35);
    map=(id)((UINavigationController *)mapEditor.presentedViewController).topViewController;
    Check(!Enabled(map,@"applyButton")&&[Status(map) containsString:@"locked after first use"],@"Used container still has honest read-only location map");
    [map cancel]; Dismiss(mapEditor);
    mapEditor=Show(nav,@"reddit",NO,NO);
    NSMutableDictionary *mismatch=[[mapEditor valueForKey:@"identity"] mutableCopy]; mismatch[@"proxyCountry"]=@"US"; mismatch[@"observedProxyCountry"]=@"CA";
    [mapEditor setValue:mismatch forKey:@"identity"];
    [mapEditor chooseLocationMap]; Pump(.35);
    map=(id)((UINavigationController *)mapEditor.presentedViewController).topViewController;
    Check(!Enabled(map,@"applyButton")&&[Status(map) containsString:@"Last observed proxy country CA"],@"Proxy-region mismatch stays visible and blocks map use");
    Snapshot(nav,@"06-location-proxy-mismatch"); [map cancel]; Dismiss(mapEditor);
    FixtureEditor *direct=[[FixtureEditor alloc] initWithContainerRow:@{@"id":NSUUID.UUID.UUIDString,@"name":@"Location tab"} simpleMode:YES];
    direct.focusRegionOnAppear=YES; [nav setViewControllers:@[direct] animated:NO]; Pump(.35);
    Check(!direct.presentedViewController,@"Location route waits for authoritative private identity");
    Complete(direct,Draft(@"iPhone14,5",@"17.2",NO),YES,nil); Pump(.35);
    Check([((UINavigationController *)direct.presentedViewController).topViewController isKindOfClass:RBXLocationPickerViewController.class],@"Location tab route opens map after draft loads");
    Dismiss(direct);
}

@interface FixtureApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation FixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    requests = [NSMutableArray new]; receipts = [NSMutableDictionary new]; drafts = [NSMutableDictionary new]; failures = [NSMutableArray new];
    method_exchangeImplementations(class_getClassMethod(UIAlertAction.class, @selector(actionWithTitle:style:handler:)), class_getClassMethod(UIAlertAction.class, @selector(fixtureActionWithTitle:style:handler:)));
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[UIViewController new]];
    self.window.rootViewController = nav; [self.window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *timer) {
        @try { RunTests(nav); } @catch (NSException *exception) { [failures addObject:[NSString stringWithFormat:@"exception %@: %@", exception.name, exception.reason]]; }
        NSDictionary *result = @{@"ok":@(failures.count == 0), @"checks":@(checks), @"failures":failures,
            @"scope":@"Actual UIKit editor; inert IPC and private drafts. Map service callbacks are injected for failure/readiness assertions; screenshots use native MapKit. No daemon, catalog freshness, jailbreak or Facebook activation proof."};
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [[NSJSONSerialization dataWithJSONObject:result options:0 error:nil] writeToURL:[documents URLByAppendingPathComponent:@"identity-result.json"] atomically:YES];
    }];
    return YES;
}
@end

int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(FixtureApp.class)); } }
