#import "SBBackendAdapter.h"
#import <MapKit/MapKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

// Recovered 3.1.0/build 1 contracts, recorded in WORKSPACE_CONTRACT.md,
// RECOVERED_SCREENS.md and Diagnostics/LBXRecoveredContextAdapter.m. This file
// isolates compatibility names; it does not reconstruct or replace the engine.
static NSString *const SBReasonHost = @"Unsupported app version";
static NSString *const SBReasonMethod = @"Backend contract unavailable";
static BOOL SBFail(NSString **reason, NSString *message) { if (reason) *reason=message; return NO; }
static void SBClear(NSString **reason) { if (reason) *reason=nil; }

#if SB_BACKEND_ADAPTER_TESTING || LBX_PRESENTATION_FIXTURE
static NSDictionary *SBFixtureMetadata;
static NSString *SBFixtureExecutable;
void SBBackendFixtureConfigure(NSDictionary *metadata, NSString *executablePath) {
    SBFixtureMetadata=[metadata copy]; SBFixtureExecutable=[executablePath copy];
}
#endif
NSDictionary *SBBackendAppMetadata(void) {
#if SB_BACKEND_ADAPTER_TESTING || LBX_PRESENTATION_FIXTURE
    if (SBFixtureMetadata) return SBFixtureMetadata;
#endif
    return NSBundle.mainBundle.infoDictionary ?: @{};
}
static NSString *SBExecutable(void) {
#if SB_BACKEND_ADAPTER_TESTING || LBX_PRESENTATION_FIXTURE
    if (SBFixtureExecutable) return SBFixtureExecutable.stringByResolvingSymlinksInPath;
#endif
    return NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
}
BOOL SBBackendMetadataSupported(NSDictionary *metadata, NSString **reason) {
    NSDictionary *expected=@{@"CFBundleIdentifier":@"com.socialbox.app", @"CFBundleExecutable":@"SocialBox",
                            @"CFBundleShortVersionString":@"3.1.0", @"CFBundleVersion":@"1"};
    if (![metadata isKindOfClass:NSDictionary.class]) return SBFail(reason,SBReasonHost);
    for (NSString *key in expected)
        if (![metadata[key] isKindOfClass:NSString.class] || ![metadata[key] isEqual:expected[key]])
            return SBFail(reason,SBReasonHost);
    SBClear(reason); return YES;
}

NSArray<NSDictionary<NSString *,id> *> *SBBackendScreenRegistry(void) {
    static NSArray *registry; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *names=@[@"unknown",@"home",@"containers",@"location",@"proxies",@"settings",@"identity",@"license",
            @"startup",@"welcome",@"country",@"carrier",@"model",@"version",@"allowedModels",@"appSelection",
            @"backups",@"cloud",@"cloudPush",@"sessionDetails",@"bulkProxyImport",@"guide",@"market",@"checkout",
            @"sessions",@"sessionImport",@"bulkCloudPush",@"sessionExport",@"sessionDestination"];
        NSArray *classes=@[@"",@"HomeViewController",@"_Xc9m",@"LocSimViewController",@"ProxyViewController",@"SettingsViewController",
            @"FakeInfoViewController",@"_Xm8u",@"_Xd2z",@"SocialBoxOnboardingViewController",@"CountryPickerViewController",
            @"CarrierPickerViewController",@"ModelPickerViewController",@"VersionPickerViewController",@"DRTAllowedModelsViewController",
            @"AppListViewController",@"BackupsViewController",@"CloudViewController",@"CloudPushViewController",
            @"TokensDetailViewController",@"BulkProxyImportViewController",@"UserGuideViewController",@"AddonsMarketViewController",
            @"CryptoCheckoutViewController",@"TokensViewController",@"TokensImportViewController",@"CMVC_BulkCloudPushViewController",@"TokensBulkExtractViewController",@"TokensRouteAllPickerViewController"];
        NSMutableArray *items=[NSMutableArray array];
        for (NSUInteger i=1;i<classes.count;i++) [items addObject:@{@"screen":@(i),@"name":names[i],@"className":classes[i],
            @"core":@(i>=SBScreenHome && i<=SBScreenSettings),@"presentation":@(i!=SBScreenMarket && i!=SBScreenCheckout)}];
        // Exact additional store surface constructed by the original plan
        // presenter (0x10007d56c). Same deny role, never a licensed Cloud route.
        [items addObject:@{@"screen":@(SBScreenMarket),@"name":@"market",@"className":@"CloudPlansViewController",@"core":@NO,@"presentation":@NO}];
        registry=[items copy];
    }); return registry;
}
static NSDictionary *SBSpec(SBScreen screen) {
    for (NSDictionary *entry in SBBackendScreenRegistry()) if ([entry[@"screen"] integerValue]==screen) return entry;
    return nil;
}
NSString *SBBackendScreenName(SBScreen screen) { return SBSpec(screen)[@"name"] ?: @"unknown"; }
NSString *SBBackendSupportedClassName(SBScreen screen) { return SBSpec(screen)[@"className"]; }
NSArray<NSString *> *SBBackendScreenClassNames(void) { return [SBBackendScreenRegistry() valueForKey:@"className"]; }
static BOOL SBImageMatches(const char *image, NSString *expected) {
    if (!image || !expected.length) return NO;
    NSString *path=[[NSString alloc] initWithUTF8String:image];
    return path && [path.stringByResolvingSymlinksInPath isEqual:expected];
}
static BOOL SBClassMatches(Class cls) { return cls && SBImageMatches(class_getImageName(cls),SBExecutable()); }
SBScreen SBBackendScreen(id controller) {
    if (!controller || !NSThread.isMainThread || !SBBackendMetadataSupported(SBBackendAppMetadata(),nil)) return SBScreenUnknown;
    Class cls=object_getClass(controller);
    if (![controller isKindOfClass:UIViewController.class] || !SBClassMatches(cls)) return SBScreenUnknown;
    NSString *name=NSStringFromClass(cls);
    for (NSDictionary *spec in SBBackendScreenRegistry()) if ([spec[@"className"] isEqual:name]) return [spec[@"screen"] integerValue];
    return SBScreenUnknown;
}

NSDictionary<NSString *,NSDictionary *> *SBBackendCompatibilityScreensDictionary(void) {
    static NSDictionary *screens; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *stack=@{@"mesh":@"meshGradientLayer",@"surface":@"contentStack",@"type":@"UIStackView"};
        NSDictionary *table=@{@"surface":@"tableView",@"type":@"UITableView"};
        NSMutableDictionary *result=[NSMutableDictionary dictionary];
        for (NSNumber *role in @[@(SBScreenHome),@(SBScreenProxies),@(SBScreenSettings),@(SBScreenIdentity),@(SBScreenGuide)])
            result[SBBackendSupportedClassName(role.integerValue)]=stack;
        for (NSNumber *role in @[@(SBScreenCountry),@(SBScreenCarrier),@(SBScreenModel),@(SBScreenVersion),@(SBScreenAllowedModels),@(SBScreenAppSelection),@(SBScreenBackups)])
            result[SBBackendSupportedClassName(role.integerValue)]=table;
        result[SBBackendSupportedClassName(SBScreenContainers)]=@{@"mesh":@"meshGradientLayer",@"surface":@"tableView",@"type":@"UITableView"};
        result[SBBackendSupportedClassName(SBScreenLocation)]=@{};
        result[SBBackendSupportedClassName(SBScreenCloud)]=@{@"surface":@"backupsTable",@"type":@"UITableView"};
        for (NSNumber *role in @[@(SBScreenCloudPush),@(SBScreenSessionDetails)])
            result[SBBackendSupportedClassName(role.integerValue)]=@{@"surface":@"table",@"type":@"UITableView"};
        result[SBBackendSupportedClassName(SBScreenBulkProxyImport)]=@{@"surface":@"previewTable",@"type":@"UITableView"};
        result[SBBackendSupportedClassName(SBScreenWelcome)]=@{@"mesh":@"meshGradientLayer"};
        result[SBBackendSupportedClassName(SBScreenStartup)]=@{@"surface":@"statusLabel",@"type":@"UILabel"};
        result[SBBackendSupportedClassName(SBScreenLicense)]=@{@"mesh":@"meshGradientLayer",@"surface":@"containerCard",@"type":@"UIView"};
        // Pinned arm64 getters: 0x1000a5aac, 0x1000ad624, 0x1000c730c,
        // 0x1000a8480 and 0x1000afa9c.
        // All return existing owned tables with exact @16@0:8 ABI. No model,
        // credential getter, session loader, upload or import worker is called.
        for(NSNumber *role in @[@(SBScreenSessions),@(SBScreenSessionImport),@(SBScreenSessionExport)])
            result[SBBackendSupportedClassName(role.integerValue)]=@{@"surface":@"table",@"type":@"UITableView",@"surfaceABI":@"@16@0:8"};
        for(NSNumber *role in @[@(SBScreenBulkCloudPush),@(SBScreenSessionDestination)])
            result[SBBackendSupportedClassName(role.integerValue)]=@{@"surface":@"tableView",@"type":@"UITableView",@"surfaceABI":@"@16@0:8"};
        screens=[result copy];
    }); return screens;
}
NSArray<NSDictionary<NSString *,id> *> *SBBackendRefreshHooks(void) {
    NSMutableArray *result=[NSMutableArray array];
    NSDictionary *methods=@{@(SBScreenHome):@[@"refreshAllCards"],@(SBScreenSettings):@[@"refreshAllCards"],
        @(SBScreenProxies):@[@"rebuildContentStack"],@(SBScreenIdentity):@[@"rebuildContent"],
        @(SBScreenContainers):@[@"loadData",@"reconfigureAllVisibleRows",@"refreshTableHeaderView"]};
    for (NSNumber *role in methods) for (NSString *selector in methods[role])
        [result addObject:@{@"className":SBBackendSupportedClassName(role.integerValue),@"selector":selector,@"returnType":@"v",@"argumentType":@""}];
    [result addObject:@{@"className":SBBackendSupportedClassName(SBScreenLocation),@"selector":@"updateUIForSimulatingState:",
                       @"returnType":@"v",@"argumentType":@(@encode(BOOL))}];
    return [result copy];
}
NSArray<NSDictionary<NSString *,id> *> *SBBackendDiagnosticHooks(void) {
    // Original Cloud/CloudPush showError: synchronously present an error alert
    // (0x100088ba8 / 0x10008e450). License showError: updates its error label
    // (0x100167000), already projected with the diagnostic role. No argument,
    // handler, license result or delayed callback is changed by this contract.
    NSMutableArray *result=[NSMutableArray array];
    for(NSNumber *role in @[@(SBScreenCloud),@(SBScreenCloudPush),@(SBScreenLicense)])
        [result addObject:@{@"className":SBBackendSupportedClassName(role.integerValue),@"selector":@"showError:",@"encoding":@"v24@0:8@16"}];
    return [result copy];
}

// Each getter descriptor is {selector, expected public class, allowed event}.
static NSArray *SBGetterSpec(SBScreen screen, NSString *key) {
    if (![key isKindOfClass:NSString.class]) return nil;
    NSDictionary *surface=SBBackendCompatibilityScreensDictionary()[SBBackendSupportedClassName(screen) ?: @""];
    if ([key isEqual:@"surface"] && surface[@"surface"]) {
        if(surface[@"surfaceABI"])return @[surface[@"surface"],surface[@"type"],@0,surface[@"surfaceABI"]];
        return @[surface[@"surface"],surface[@"type"],@0];
    }
    if ([key isEqual:@"mesh"] && surface[@"mesh"]) return @[surface[@"mesh"],@"CALayer",@0];
    NSDictionary *getters=nil;
    switch (screen) {
        case SBScreenHome: getters=@{
            @"logo":@[@"logoView",@"UIImageView",@0],
            @"identity.modelName":@[@"modelNameValue",@"UILabel",@0],@"identity.deviceName":@[@"deviceNameValue",@"UILabel",@0],
            @"identity.osVersion":@[@"iosVersionValue",@"UILabel",@0],@"identity.modelNumber":@[@"modelNumberValue",@"UILabel",@0],
            @"identity.serial":@[@"serialValue",@"UILabel",@0],@"identity.carrier":@[@"carrierValue",@"UILabel",@0],
            @"identity.mobileCodes":@[@"mccMncValue",@"UILabel",@0],@"identity.wifi":@[@"wifiValue",@"UILabel",@0],
            @"identity.bluetooth":@[@"btValue",@"UILabel",@0],@"identity.ethernet":@[@"ethernetValue",@"UILabel",@0],
            @"identity.imei":@[@"imeiValue",@"UILabel",@0],@"identity.meid":@[@"meidValue",@"UILabel",@0],
            @"identity.iccid":@[@"iccidValue",@"UILabel",@0],@"identity.advertisingID":@[@"idfaValue",@"UILabel",@0],
            @"identity.vendorID":@[@"idfvValue",@"UILabel",@0],@"identity.deviceID":@[@"udidValue",@"UILabel",@0],
            @"create":@[@"fingerprintButton",@"UIButton",@(UIControlEventTouchUpInside)],
            @"identity.create":@[@"fingerprintButton",@"UIButton",@(UIControlEventTouchUpInside)],
            @"identity.toggle":@[@"mainToggle",@"UISwitch",@(UIControlEventValueChanged)]}; break;
        case SBScreenSettings: getters=@{
            @"connection.status":@[@"connectionStatusLabel",@"UILabel",@0],@"connection.device":@[@"deviceIdLabel",@"UILabel",@0],
            @"connection.jailbreak":@[@"jailbreakTypeLabel",@"UILabel",@0],@"license.key":@[@"licenseKeyLabel",@"UILabel",@0],
            @"license.devices":@[@"deviceCountLabel",@"UILabel",@0],@"license.plan":@[@"planTitleLabel",@"UILabel",@0],
            @"license.status":@[@"planStatusLabel",@"UILabel",@0]}; break;
        case SBScreenIdentity: getters=@{@"identity.country":@[@"countryValueLabel",@"UILabel",@0]}; break;
        case SBScreenLicense: getters=@{
            @"title":@[@"titleLabel",@"UILabel",@0],@"license.field":@[@"licenseKeyField",@"UITextField",@0],
            @"license.button":@[@"validateButton",@"UIButton",@(UIControlEventTouchUpInside)],
            @"license.loading":@[@"loadingLabel",@"UILabel",@0],@"license.error":@[@"errorLabel",@"UILabel",@0]}; break;
        case SBScreenStartup: getters=@{@"logo":@[@"logoImageView",@"UIImageView",@0],
            @"startup.spinner":@[@"spinner",@"UIActivityIndicatorView",@0],@"startup.status":@[@"statusLabel",@"UILabel",@0]}; break;
        case SBScreenLocation: getters=@{
            @"search":@[@"searchBar",@"UISearchBar",@0],@"map":@[@"mapView",@"MKMapView",@0],
            @"location.coordinates":@[@"coordsLabel",@"UILabel",@0],@"location.address":@[@"addressLabel",@"UILabel",@0],
            @"location.status":@[@"statusLabel",@"UILabel",@0],@"location.button":@[@"actionButton",@"UIButton",@(UIControlEventTouchUpInside)],
            @"location.presets":@[@"presetsScrollView",@"UIScrollView",@0]}; break;
        case SBScreenContainers: case SBScreenProxies: case SBScreenCountry: case SBScreenCarrier:
            getters=@{@"search":@[@"searchBar",@"UISearchBar",@0]}; break;
        case SBScreenBackups: getters=@{@"search":@[@"searchBar",@"UISearchBar",@0],@"detail":@[@"headerLabel",@"UILabel",@0]}; break;
        case SBScreenCloudPush: getters=@{@"search":@[@"searchBar",@"UISearchBar",@0],@"detail":@[@"headerLabel",@"UILabel",@0],
            @"filter":@[@"filterButton",@"UIButton",@(UIControlEventTouchUpInside)]}; break;
        case SBScreenSessionDetails: getters=@{@"mode":@[@"modeControl",@"UISegmentedControl",@(UIControlEventValueChanged)],
            @"loading":@[@"loadingLabel",@"UILabel",@0],@"activity":@[@"spinner",@"UIActivityIndicatorView",@0]}; break;
        case SBScreenSessions: getters=@{@"activity":@[@"spinner",@"UIActivityIndicatorView",@0,@"@16@0:8"]}; break;
        case SBScreenSessionDestination:
            // 0x1000afa78. Filter remains the original navigation bar item;
            // completion, selected ID and model arrays are never read.
            getters=@{@"search":@[@"searchBar",@"UISearchBar",@0,@"@16@0:8"]}; break;
        case SBScreenBulkCloudPush:
            // 0x1000c72c4 / 0x1000c72e8: UIKit fields only. Their original
            // delegate, secure-entry state and values remain authoritative.
            getters=@{@"label":@[@"labelField",@"UITextField",@0,@"@16@0:8"],
                @"passphrase":@[@"passphraseField",@"UITextField",@0,@"@16@0:8"]}; break;
        case SBScreenBulkProxyImport: getters=@{@"input":@[@"inputView",@"UITextView",@0],
            @"mode":@[@"protocolPicker",@"UISegmentedControl",@(UIControlEventValueChanged)],@"detail":@[@"summaryLabel",@"UILabel",@0],
            @"submit":@[@"importButton",@"UIButton",@(UIControlEventTouchUpInside)]}; break;
        case SBScreenCloud: getters=@{@"quota":@[@"quotaValueLabel",@"UILabel",@0],@"tier":@[@"tierBadgeLabel",@"UILabel",@0],
            @"activity":@[@"spinner",@"UIActivityIndicatorView",@0],@"selectionToolbar":@[@"selectionToolbar",@"UIView",@0],
            @"selectionDelete":@[@"bulkDeleteButton",@"UIButton",@(UIControlEventTouchUpInside)],
            @"selectionPull":@[@"bulkPullButton",@"UIButton",@(UIControlEventTouchUpInside)]}; break;
        case SBScreenAppSelection: getters=@{@"activity":@[@"loadingIndicator",@"UIActivityIndicatorView",@0]}; break;
        default: break;
    }
    return getters[key];
}
static BOOL SBType(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    while (*actual && strchr("rnNoORV",*actual)) actual++;
    return expected[0]=='@' ? actual[0]=='@' && actual[1]!='?' : !strcmp(actual,expected);
}
static IMP SBImplementation(Method method, BOOL allowUIKitTable) {
    if (!method) return NULL;
    IMP implementation=method_getImplementation(method); Dl_info info={0};
    if (!implementation || !dladdr((const void *)implementation,&info) || !info.dli_fname) return NULL;
    if (allowUIKitTable) {
        const char *systemImage=class_getImageName(UITableViewController.class);
        if (systemImage && SBImageMatches(info.dli_fname,[@(systemImage) stringByResolvingSymlinksInPath])) return implementation;
    }
    return SBImageMatches(info.dli_fname,SBExecutable()) ? implementation : NULL;
}
static Method SBMethod(id object, NSString *selectorName, const char *returnType, const char *argumentType, BOOL allowUIKitTable) {
    Class cls=object_getClass(object);
    if (!object || !SBClassMatches(cls)) return NULL;
    SEL selector=NSSelectorFromString(selectorName); Method method=class_getInstanceMethod(cls,selector);
    if (!method || method_getNumberOfArguments(method)!=(argumentType ? 3u : 2u)) return NULL;
    char *ret=method_copyReturnType(method); BOOL valid=SBType(ret,returnType); free(ret);
    if (argumentType) { char *arg=method_copyArgumentType(method,2); valid=valid && SBType(arg,argumentType); free(arg); }
    if (!valid) return NULL;
    return SBImplementation(method,allowUIKitTable) ? method : NULL;
}
static SBScreen SBReady(id owner, NSString **reason) {
    if (!NSThread.isMainThread) { SBFail(reason,@"Main thread required"); return SBScreenUnknown; }
    if (!SBBackendMetadataSupported(SBBackendAppMetadata(),reason)) return SBScreenUnknown;
    SBScreen screen=SBBackendScreen(owner);
    if (screen==SBScreenUnknown) { SBFail(reason,@"Unsupported screen"); return screen; }
    if (![owner isViewLoaded]) { SBFail(reason,@"Screen has not loaded"); return SBScreenUnknown; }
    return screen;
}
id SBBackendReadObject(id owner, NSString *key, NSString **reason) {
    SBClear(reason); SBScreen screen=SBReady(owner,reason); if (!screen) return nil;
    NSArray *spec=SBGetterSpec(screen,key); if (!spec) { SBFail(reason,@"Unsupported presentation field"); return nil; }
    BOOL table=[spec[0] isEqual:@"tableView"] && [owner isKindOfClass:UITableViewController.class] &&
        (screen==SBScreenModel || screen==SBScreenVersion || screen==SBScreenAllowedModels || screen==SBScreenAppSelection);
    Method method=SBMethod(owner,spec[0],"@",NULL,table);
    if(method && spec.count>3 && strcmp(method_getTypeEncoding(method),[spec[3] UTF8String])) method=NULL;
    if (!method) { SBFail(reason,SBReasonMethod); return nil; }
    @try {
        IMP implementation=SBImplementation(method,table);
        if (!implementation) { SBFail(reason,SBReasonMethod); return nil; }
        id value=((id(*)(id,SEL))implementation)(owner,method_getName(method));
        if (![value isKindOfClass:NSClassFromString(spec[1])]) { SBFail(reason,@"Presentation field unavailable"); return nil; }
        if ([value isKindOfClass:UIView.class] && value!=[owner view] && ![value isDescendantOfView:[owner view]]) {
            SBFail(reason,@"Presentation field is outside this screen"); return nil;
        }
        if ([value isKindOfClass:CALayer.class]) {
            CALayer *root=[[owner view] layer], *cursor=value;
            while (cursor && cursor!=root) cursor=cursor.superlayer;
            if (cursor!=root) { SBFail(reason,@"Presentation layer is outside this screen"); return nil; }
        }
        return value;
    } @catch (__unused NSException *exception) { SBFail(reason,@"Presentation field read failed"); return nil; }
}

// Only reviewed original user-entry methods. No direct perform/reset worker,
// license verdict, storage writer, singleton, or arbitrary selector is exposed.
static NSString *SBActionSelector(SBScreen screen, NSString *action) {
    NSDictionary *actions=nil;
    switch (screen) {
        case SBScreenHome: actions=@{@"home.configureIdentity":@"openConfigureSpoofing",@"home.cloud":@"openCloud",
            @"home.backups":@"showBackupPicker",@"home.apps":@"selectAppToSpoof",@"home.sessions":@"openTokens",@"home.stopApp":@"showKillAppDialog"}; break;
        case SBScreenSettings: actions=@{@"settings.copySeed":@"copySeed",@"settings.importSeed":@"importSeed",
            @"settings.reloadInterface":@"confirmSbreload",@"settings.restartSpringBoard":@"confirmRespring",
            @"settings.restartUserspace":@"confirmUserspaceReboot",@"settings.cleanOrphans":@"confirmCleanCrane",
            @"settings.recoverLauncher":@"confirmRecoverPalera1n",@"settings.recoverService":@"confirmRecoverDaemon",
            @"settings.reset":@"resetSettings",@"settings.signOut":@"logout"}; break;
        case SBScreenWelcome: actions=@{@"welcome.create":@"tapCreate",@"welcome.skip":@"tapSkip"}; break;
        case SBScreenLocation: actions=@{@"location.proxy":@"setLocationToProxy",@"location.bookmarks":@"showBookmarksMenu",
            @"location.history":@"showHistoryMenu",@"location.mapStyle":@"toggleMapType",@"location.device":@"locateMe",
            @"location.copy":@"copyCoordinates",@"location.verify":@"verifySpoof"}; break;
        case SBScreenProxies: actions=@{@"proxies.add":@"showAddProxyMenu"}; break;
        case SBScreenContainers: actions=@{@"containers.import":@"importContainerTapped",@"containers.default":@"confirmSwitchToDefault"}; break;
        case SBScreenCloud: actions=@{@"cloud.passphrases":@"presentPassphraseManager",@"cloud.pushHelp":@"presentPushHelp",
            @"cloud.reload":@"reloadBackupsFromServer"}; break;
        default: break;
    }
    return [action isKindOfClass:NSString.class] ? actions[action] : nil;
}
static NSString *SBActionControl(SBScreen screen, NSString *action) {
    NSDictionary *controls=@{@(SBScreenHome):@{@"home.create":@"create",@"home.toggleIdentity":@"identity.toggle"},
        @(SBScreenLocation):@{@"location.toggle":@"location.button"},
        @(SBScreenBulkProxyImport):@{@"bulk.import":@"submit"},
        @(SBScreenCloud):@{@"cloud.deleteSelected":@"selectionDelete",@"cloud.restoreSelected":@"selectionPull"}};
    return [action isKindOfClass:NSString.class] ? controls[@(screen)][action] : nil;
}
static UIControl *SBControl(id owner, NSString *key, UIControlEvents event, NSString **reason) {
    SBScreen screen=SBReady(owner,reason); if (!screen) return nil;
    NSArray *spec=SBGetterSpec(screen,key);
    if (!spec || !event || [spec[2] unsignedLongLongValue]!=(unsigned long long)event) {
        SBFail(reason,@"Unsupported control event"); return nil;
    }
    id control=SBBackendReadObject(owner,key,reason); if (!control) return nil;
    if (![control isKindOfClass:UIControl.class] || ![control isEnabled] || [control isHidden]) {
        SBFail(reason,@"Action is currently unavailable"); return nil;
    }
    return control;
}
BOOL SBBackendActionAvailable(id owner, NSString *action, id nativeSender, NSString **reason) {
    SBClear(reason); SBScreen screen=SBReady(owner,reason); if (!screen) return NO;
    NSString *key=SBActionControl(screen,action);
    if (key) {
        UIControl *control=SBControl(owner,key,[SBGetterSpec(screen,key)[2] unsignedLongLongValue],reason);
        if (!control) return NO;
        return !nativeSender || nativeSender==control ? YES : SBFail(reason,@"Original control sender required");
    }
    NSString *selector=SBActionSelector(screen,action);
    if (!selector) return SBFail(reason,@"Unsupported action");
    if (nativeSender) return SBFail(reason,@"This action takes no sender");
    return SBMethod(owner,selector,"v",NULL,NO) ? YES : SBFail(reason,SBReasonMethod);
}
BOOL SBBackendSendControl(id owner, NSString *key, UIControlEvents event, NSString **reason) {
    SBClear(reason); UIControl *control=SBControl(owner,key,event,reason); if (!control) return NO;
    @try { [control sendActionsForControlEvents:event]; return YES; }
    @catch (__unused NSException *exception) { return SBFail(reason,@"Action dispatch failed"); }
}
BOOL SBBackendInvoke(id owner, NSString *action, id nativeSender, NSString **reason) {
    if (!SBBackendActionAvailable(owner,action,nativeSender,reason)) return NO;
    SBScreen screen=SBBackendScreen(owner); NSString *key=SBActionControl(screen,action);
    if (key) return SBBackendSendControl(owner,key,[SBGetterSpec(screen,key)[2] unsignedLongLongValue],reason);
    // Recheck and dispatch the exact captured implementation, not an unchecked
    // objc_msgSend lookup after validating another implementation.
    Method method=SBMethod(owner,SBActionSelector(screen,action),"v",NULL,NO);
    IMP implementation=SBImplementation(method,NO);
    if (!implementation) return SBFail(reason,SBReasonMethod);
    @try { ((void(*)(id,SEL))implementation)(owner,method_getName(method)); return YES; }
    @catch (__unused NSException *exception) { return SBFail(reason,@"Action dispatch failed"); }
}

@interface SBContainerRecord ()
@property(nonatomic,readwrite,copy) NSString *identifier;
@property(nonatomic,readwrite,copy) NSString *name;
@property(nonatomic,readwrite,copy) NSArray<NSString *> *appBundleIDs;
@property(nonatomic,readwrite) BOOL appMembershipAvailable;
@property(nonatomic,readwrite,copy) NSString *proxyTitle;
@property(nonatomic,readwrite,copy) NSString *profileIdentifier;
@property(nonatomic,readwrite,copy) NSString *folderName;
@end
@implementation SBContainerRecord
@end
@interface SBContainerSnapshot ()
@property(nonatomic,readwrite) BOOL available;
@property(nonatomic,readwrite,copy) NSString *reason;
@property(nonatomic,readwrite,copy) NSArray<SBContainerRecord *> *containers;
@property(nonatomic,readwrite,copy) NSString *activeIdentifier;
@end
@implementation SBContainerSnapshot
@end
static SBContainerSnapshot *SBUnavailable(NSString *reason) {
    SBContainerSnapshot *snapshot=[SBContainerSnapshot new]; snapshot.reason=reason; snapshot.containers=@[]; return snapshot;
}
static Method SBModelGetter(id object, NSString *className, NSString *selector, const char *encoding, const char *returnType) {
    if (object_getClass(object)!=NSClassFromString(className)) return NULL;
    Method method=SBMethod(object,selector,returnType,NULL,NO);
    return method && !strcmp(method_getTypeEncoding(method),encoding) ? method : NULL;
}
static IMP SBRequiredImplementation(Method method) {
    IMP implementation=SBImplementation(method,NO);
    if (!implementation) @throw [NSException exceptionWithName:@"SBBackendChanged" reason:nil userInfo:nil];
    return implementation;
}
static id SBObject(id object, Method method) { return ((id(*)(id,SEL))SBRequiredImplementation(method))(object,method_getName(method)); }
static long long SBInteger(id object, Method method) { return ((long long(*)(id,SEL))SBRequiredImplementation(method))(object,method_getName(method)); }
static BOOL SBBundleID(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>255) return NO;
    NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location==NSNotFound && ![value hasPrefix:@"."] && ![value hasSuffix:@"."] &&
        [value rangeOfString:@".."].location==NSNotFound && [value rangeOfString:@"."].location!=NSNotFound;
}
static NSString *SBBoundedText(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value length]<=limit &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound ? [value copy] : nil;
}
static NSString *SBOptionalModelText(id row, NSString *selector) {
    Method getter=SBModelGetter(row,@"_Xv8i",selector,"@16@0:8","@");
    return getter ? SBBoundedText(SBObject(row,getter),512) : nil;
}
SBContainerSnapshot *SBBackendContainers(id owner) {
    NSString *reason=nil;
    if (SBReady(owner,&reason)!=SBScreenContainers) return SBUnavailable(reason ?: @"Unsupported screen");
    // Exact getter contract: controller containers/activeContainerID at
    // 0x1001295dc/600; model containerID/name/apps 0x1003065a8/5b8/64c.
    // Never call loadData, toDictionary, a singleton factory, or a switch.
    Method list=SBModelGetter(owner,@"_Xc9m",@"containers","@16@0:8","@");
    Method selected=SBModelGetter(owner,@"_Xc9m",@"activeContainerID","q16@0:8","q");
    if (!list || !selected) return SBUnavailable(SBReasonMethod);
    @try {
        long long before=SBInteger(owner,selected); id raw=SBObject(owner,list);
        if (![raw isKindOfClass:NSArray.class] || [raw count]>4096) return SBUnavailable(@"Invalid container list");
        NSMutableArray *records=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
        for (id row in [raw copy]) {
            Method identifier=SBModelGetter(row,@"_Xv8i",@"containerID","q16@0:8","q");
            Method name=SBModelGetter(row,@"_Xv8i",@"name","@16@0:8","@");
            Method apps=SBModelGetter(row,@"_Xv8i",@"apps","@16@0:8","@");
            if (!identifier || !name || !apps) return SBUnavailable(@"Unsupported container contract");
            long long number=SBInteger(row,identifier); id rawName=SBObject(row,name), rawApps=SBObject(row,apps);
            if (number<=0 || [seen containsObject:@(number)] || ![rawName isKindOfClass:NSString.class] ||
                ![rawName length] || [rawName length]>512 || [rawName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
                return SBUnavailable(@"Invalid container metadata");
            if (rawApps && (![rawApps isKindOfClass:NSArray.class] || [rawApps count]>256)) return SBUnavailable(@"Invalid app membership");
            NSMutableArray *appIDs=[NSMutableArray array]; NSMutableSet *seenApps=[NSMutableSet set];
            for (id app in [rawApps copy]) {
                if (!SBBundleID(app) || [seenApps containsObject:app]) return SBUnavailable(@"Invalid app membership");
                [seenApps addObject:app]; [appIDs addObject:[app copy]];
            }
            SBContainerRecord *record=[SBContainerRecord new]; record.identifier=[NSString stringWithFormat:@"%lld",number];
            record.name=rawName; record.appBundleIDs=appIDs; record.appMembershipAvailable=rawApps!=nil;
            // Exact ivar-return getters, metadata @16@0:8. These are display
            // labels/identifiers only, not proxy credentials or full profiles.
            record.proxyTitle=SBOptionalModelText(row,@"proxyTitle");
            record.profileIdentifier=SBOptionalModelText(row,@"spoofProfileID");
            // Read-only cached folder search, @24@0:8q16, 0x100105890.
            Method folder=SBMethod(owner,@"folderNameForContainerID:","@","q",NO);
            if (folder && !strcmp(method_getTypeEncoding(folder),"@24@0:8q16"))
                record.folderName=SBBoundedText(((id(*)(id,SEL,long long))SBRequiredImplementation(folder))(owner,method_getName(folder),number),512);
            [records addObject:record]; [seen addObject:@(number)];
        }
        if (before!=SBInteger(owner,selected)) return SBUnavailable(@"Selection changed during read");
        SBContainerSnapshot *snapshot=[SBContainerSnapshot new]; snapshot.available=YES;
        snapshot.reason=@"Cached presentation metadata only"; snapshot.containers=records;
        if (before>0 && [seen containsObject:@(before)]) snapshot.activeIdentifier=[NSString stringWithFormat:@"%lld",before];
        return snapshot;
    } @catch (__unused NSException *exception) { return SBUnavailable(@"Container read failed"); }
}

static NSString *SBContainerActionSelector(NSString *action) {
    // Exact metadata v24@0:8@16, in original _Xc9m. These are the original
    // menu endpoints, preserving prompts and backend policy. No worker selector.
    return [action isKindOfClass:NSString.class] ? (@{
        @"container.switch":@"confirmSwitchToContainer:",       // 0x100111058
        @"container.apps":@"editAppsForContainer:",             // 0x100115fd8
        @"container.proxy":@"showProxyPickerForContainer:",     // 0x10010fcf8
        @"container.rename":@"renameContainer:",                // 0x10011a060
        @"container.export":@"exportContainer:",                // 0x10011ca54
        @"container.delete":@"confirmDeleteContainer:",         // 0x100116764
        @"container.newFolder":@"createFolderAndMoveContainer:",// 0x1001285a4
        @"container.removeFolder":@"removeContainerFromFolder:" // 0x100128358
    })[action] : nil;
}
static id SBResolveContainer(id owner, NSString *identifier, NSString *action, NSString **reason) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length>19 ||
        [identifier rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound ||
        identifier.longLongValue<=0 || ![[NSString stringWithFormat:@"%lld",identifier.longLongValue] isEqual:identifier]) {
        SBFail(reason,@"Invalid container identifier"); return nil;
    }
    SBContainerSnapshot *snapshot=SBBackendContainers(owner);
    if (!snapshot.available) { SBFail(reason,snapshot.reason); return nil; }
    BOOL found=NO; for (SBContainerRecord *record in snapshot.containers) if ([record.identifier isEqual:identifier]) found=YES;
    if (!found) { SBFail(reason,@"Container is no longer available"); return nil; }
    // The original menu disables deleting its current active context.
    if ([action isEqual:@"container.delete"] && [snapshot.activeIdentifier isEqual:identifier]) {
        SBFail(reason,@"Switch away before deleting this container"); return nil;
    }
    // Re-read the current list and exact ID getter after snapshot validation.
    // Reordering must not change the target; duplicate/replaced lists fail.
    Method list=SBModelGetter(owner,@"_Xc9m",@"containers","@16@0:8","@");
    Method active=SBModelGetter(owner,@"_Xc9m",@"activeContainerID","q16@0:8","q");
    if (!list || !active) { SBFail(reason,SBReasonMethod); return nil; }
    id raw=SBObject(owner,list); if (![raw isKindOfClass:NSArray.class] || [raw count]>4096) { SBFail(reason,@"Invalid container list"); return nil; }
    id resolved=nil; NSMutableSet *seen=[NSMutableSet set];
    for (id row in [raw copy]) {
        Method idGetter=SBModelGetter(row,@"_Xv8i",@"containerID","q16@0:8","q");
        if (!idGetter) { SBFail(reason,@"Unsupported container contract"); return nil; }
        long long number=SBInteger(row,idGetter);
        if (number<=0 || [seen containsObject:@(number)]) { SBFail(reason,@"Invalid container metadata"); return nil; }
        [seen addObject:@(number)];
        if (number==identifier.longLongValue) resolved=row;
    }
    if (!resolved) { SBFail(reason,@"Container is no longer available"); return nil; }
    if ([action isEqual:@"container.delete"] && SBInteger(owner,active)==identifier.longLongValue) {
        SBFail(reason,@"Switch away before deleting this container"); return nil;
    }
    return resolved;
}
BOOL SBBackendContainerActionAvailable(id owner, NSString *action, NSString *identifier, NSString **reason) {
    SBClear(reason);
    if (SBReady(owner,reason)!=SBScreenContainers) return SBFail(reason,@"Unsupported screen");
    NSString *selector=SBContainerActionSelector(action);
    if (!selector) return SBFail(reason,@"Unsupported container action");
    Method method=SBMethod(owner,selector,"v","@",NO);
    if (!method || strcmp(method_getTypeEncoding(method),"v24@0:8@16")) return SBFail(reason,SBReasonMethod);
    @try { return SBResolveContainer(owner,identifier,action,reason)!=nil; }
    @catch (__unused NSException *exception) { return SBFail(reason,@"Container read failed"); }
}
BOOL SBBackendInvokeContainerAction(id owner, NSString *action, NSString *identifier, NSString **reason) {
    if (!SBBackendContainerActionAvailable(owner,action,identifier,reason)) return NO;
    @try {
        id row=SBResolveContainer(owner,identifier,action,reason); if (!row) return NO;
        Method method=SBMethod(owner,SBContainerActionSelector(action),"v","@",NO);
        if (!method || strcmp(method_getTypeEncoding(method),"v24@0:8@16")) return SBFail(reason,SBReasonMethod);
        ((void(*)(id,SEL,id))SBRequiredImplementation(method))(owner,method_getName(method),row);
        return YES; // Dispatch only; original backend owns completion/failure.
    } @catch (__unused NSException *exception) { return SBFail(reason,@"Container action dispatch failed"); }
}
SBContainerRecord *SBBackendContainerAtIndexPath(id owner, NSIndexPath *indexPath) {
    if (SBReady(owner,nil)!=SBScreenContainers || ![indexPath isKindOfClass:NSIndexPath.class] || indexPath.length!=2 ||
        indexPath.section<0 || indexPath.row<0) return nil;
    Method method=SBMethod(owner,@"containerInfoAtIndexPath:","@","@",NO);
    if (!method || strcmp(method_getTypeEncoding(method),"@24@0:8@16")) return nil;
    @try {
        id row=((id(*)(id,SEL,id))SBRequiredImplementation(method))(owner,method_getName(method),indexPath);
        Method idGetter=SBModelGetter(row,@"_Xv8i",@"containerID","q16@0:8","q");
        if (!idGetter) return nil;
        NSString *identifier=[NSString stringWithFormat:@"%lld",SBInteger(row,idGetter)];
        SBContainerSnapshot *snapshot=SBBackendContainers(owner); if (!snapshot.available) return nil;
        for (SBContainerRecord *record in snapshot.containers) if ([record.identifier isEqual:identifier]) return record;
    } @catch (__unused NSException *exception) { }
    return nil;
}
