#import "RBXAppScope.h"
#import "RBXIdentityViewController.h"
#import "RBXCatalogPickerViewController.h"
#import "RBXLocationPickerViewController.h"
#import "RBXScreenRecommendation.h"
#import "RBXLauncherIPC.h"
#import "RBXAppearance.h"
#import "RBXOperatorWording.h"
#import "RBXIdentityReview.h"
#import "RBXIdentityHelp.h"
#import "RBXIdentityFields.h"
#import "RBXInstallPaths.h"
#import "RBXSecureConfig.h"

@interface RBXIdentityViewController ()
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic, copy) NSDictionary *row;
@property(nonatomic, copy) NSDictionary *identity;
@property(nonatomic, copy) NSString *pendingRequestId;
@property(nonatomic) BOOL resultRetryScheduled;
@property(nonatomic) BOOL pendingAutomaticFill;
@property(nonatomic, copy) NSDictionary *pendingAutomaticSecurity;
@property(nonatomic, strong) UIButton *sentinelSaveButton;
@property(nonatomic, strong) UISwitch *sentinelSwitch;
@property(nonatomic, strong) UISwitch *sentinelClipboardSwitch;
@property(nonatomic, strong) UITextField *sentinelInterval;
@property(nonatomic, strong) UISegmentedControl *modeControl;
@property(nonatomic, strong) UITextField *productTypeField;
@property(nonatomic, strong) UILabel *modelLabel;
@property(nonatomic, strong) UITextField *iosVersionField;
@property(nonatomic, strong) UITextField *countryField;
@property(nonatomic, strong) UITextField *localeField;
@property(nonatomic, strong) UITextField *timezoneField;
@property(nonatomic, strong) UITextField *carrierField;
@property(nonatomic, strong) UITextField *cityField;
@property(nonatomic, strong) UILabel *regionStatusLabel;
@property(nonatomic, strong) UITextField *deviceNameField;
@property(nonatomic, strong) UITextField *batteryField;
@property(nonatomic, strong) UISegmentedControl *idfaControl;
@property(nonatomic, strong) UISegmentedControl *fontControl;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *securitySwitches;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *identifierFields;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *identifierStatusLabel;
@property(nonatomic, strong) UILabel *derivedIdentityLabel;
@property(nonatomic, strong) UIButton *applyButton;
@property(nonatomic, strong) UIButton *randomButton;
@property(nonatomic, strong) UIButton *checkButton;
@property(nonatomic) BOOL identityLoaded;
@property(nonatomic, strong) NSMutableArray<UIButton *> *catalogButtons;
@property(nonatomic) BOOL simpleMode;
@property(nonatomic, copy) NSDictionary *pendingChoices;
@property(nonatomic, copy) NSDictionary *validatedChoices;
@property(nonatomic, strong) UIScrollView *identityScroll;
@property(nonatomic, strong) UIStackView *regionSection;
@property(nonatomic, strong) UIStackView *pageStack;
@property(nonatomic, strong) UIStackView *advancedStack;
@property(nonatomic, strong) UIButton *advancedButton;
@property(nonatomic, strong) UIButton *locationMapButton;
@property(nonatomic) BOOL openLocationMapWhenLoaded;
- (void)loadResult;
@end

static void RBXIdentityStateChanged(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    RBXIdentityViewController *controller =
        (__bridge RBXIdentityViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller loadResult]; });
}

@implementation RBXIdentityViewController

- (instancetype)initWithContainerRow:(NSDictionary *)row {
    return [self initWithContainerRow:row simpleMode:NO];
}

- (instancetype)initWithContainerRow:(NSDictionary *)row simpleMode:(BOOL)simpleMode {
    NSDictionary *descriptor = RBXAppDescriptorForProfile(row);
    if (!descriptor) return nil;
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _simpleMode = simpleMode;
        _appDescriptor = descriptor;
        _row = [row copy];
        _identity = [row[@"identityEditor"] isKindOfClass:[NSDictionary class]]
            ? [row[@"identityEditor"] copy] : @{};
        _securitySwitches = [NSMutableDictionary dictionary];
        _identifierFields = [NSMutableDictionary dictionary];
        _catalogButtons = [NSMutableArray array];
    }
    return self;
}

- (UILabel *)caption:(NSString *)text {
    return RBXLabel(text, UIFontTextStyleFootnote, YES);
}

- (void)addHelp:(NSString *)key to:(UIStackView *)stack {
    NSString *text = RBXIdentityFieldHelp(key);
    if (text.length) [stack addArrangedSubview:[self caption:text]];
}

- (UITextField *)field:(NSString *)placeholder value:(NSString *)value {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.text = value;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    RBXStyleField(field);
    [field addTarget:self action:@selector(choicesChanged) forControlEvents:UIControlEventEditingChanged];
    return field;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(requestsDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    self.title = [NSString stringWithFormat:@"%@ Identity",
        self.row[@"name"] ?: @"Container"];
    self.view.backgroundColor = RBXCanvasColor();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.tintColor = RBXAccentColor();

    UIScrollView *scroll = [UIScrollView new];
    self.identityScroll = scroll;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-30],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    UIStackView *page = stack;
    self.pageStack = page;
    stack = RBXFormSection(page, @"Edit identity",
        @"Choose how to prepare this draft. Automatically fill prepares the entire supported identity: identifiers, hardware, software, location, carrier, presentation and timing. Set manually keeps the loaded values for editing. Review, Check and Save are separate steps; identity is locked after first use.");
    self.statusLabel = [self caption:@"Loading saved identity…"];
    [stack addArrangedSubview:self.statusLabel];
    self.modeControl = [[UISegmentedControl alloc]
        initWithItems:@[@"Automatically fill", @"Set manually"]];
    self.modeControl.selectedSegmentIndex = 1;
    [self.modeControl addTarget:self action:@selector(editingModeChanged) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.modeControl];
    [self addHelp:@"automaticFill" to:stack];
    self.randomButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.randomButton setTitle:@"Fill automatically" forState:UIControlStateNormal];
    RBXStyleButton(self.randomButton, NO);
    [self.randomButton addTarget:self action:@selector(automaticFill) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.randomButton];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Reload" style:UIBarButtonItemStylePlain target:self action:@selector(reloadIdentity)];

    stack = RBXFormSection(page, @"Device identity", nil);
    self.modelLabel = [self caption:self.identity[@"marketingName"] ?: @"Choose a model"];
    [stack addArrangedSubview:self.modelLabel];
    self.productTypeField = [self field:@"iPhone product type"
        value:self.identity[@"productType"] ?: @""];
    [stack addArrangedSubview:self.productTypeField];
    [self addHelp:@"productType" to:stack];
    self.productTypeField.userInteractionEnabled = NO;
    [self addCatalogButton:@"Choose model" to:stack action:@selector(chooseModel)];
    [stack addArrangedSubview:[self caption:
        @"Choose a supported catalog model and iOS version. This synthetic identity can differ from the phone; it does not change physical hardware or the OS needed to run the app."]];
    NSDictionary *physical=[self physicalScreenMetrics];
    [stack addArrangedSubview:[self caption:[NSString stringWithFormat:
        @"This screen: %@ × %@ native pixels; %@ × %@ points, %@× scale (native %@×). The model picker ranks matching geometry first. A screen match does not verify every hardware property.",
        physical[@"nativeWidth"],physical[@"nativeHeight"],physical[@"logicalWidth"],physical[@"logicalHeight"],physical[@"scale"],physical[@"nativeScale"]]]];

    [stack addArrangedSubview:[self caption:@"iOS version"]];
    self.iosVersionField = [self field:@"Catalog iOS version"
        value:self.identity[@"iosVersion"] ?: @""];
    [stack addArrangedSubview:self.iosVersionField];
    [self addHelp:@"iosVersion" to:stack];
    self.iosVersionField.userInteractionEnabled = NO;
    [self addCatalogButton:@"Choose iOS version" to:stack action:@selector(chooseIOS)];

    stack = RBXFormSection(page, @"Region & carrier", nil);
    self.regionSection = stack;
    if (!self.creationDraftToken.length) [self addCatalogButton:@"Set from proxy" to:stack action:@selector(detectProxyRegion)];
    else [stack addArrangedSubview:[self caption:@"Country was checked through the selected proxy when this draft was prepared. To use another proxy, discard this draft and prepare again."]];
    self.regionStatusLabel = [self caption:@"Detect the country and time zone through this container’s assigned proxy, or the selected device proxy before assignment. Language and carrier are suggested values. Changes stay in this draft until saved."];
    [stack addArrangedSubview:self.regionStatusLabel];
    NSString *proxyCaption =
        [self.identity[@"proxyCountrySource"] isEqualToString:@"observed"]
            ? [NSString stringWithFormat:@"Country (configured %@ • last live exit %@)",
                self.identity[@"proxyCountry"] ?: @"unknown",
                self.identity[@"observedProxyCountry"] ?: @"unknown"]
            : [NSString stringWithFormat:@"Country (configured proxy country: %@; live exit is checked when opening)",
                self.identity[@"proxyCountry"] ?: @"unknown"];
    [stack addArrangedSubview:[self caption:proxyCaption]];
    self.countryField = [self field:@"US" value:self.identity[@"country"] ?: @""];
    self.countryField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    [self.countryField addTarget:self action:@selector(updateLocalWarning)
                forControlEvents:UIControlEventEditingChanged];
    [stack addArrangedSubview:self.countryField];
    [self addHelp:@"country" to:stack];
    [self addCatalogButton:@"Choose region" to:stack action:@selector(chooseRegion)];
    [stack addArrangedSubview:[self caption:@"Language & region"]];
    self.localeField = [self field:@"Locale, e.g. en_US"
        value:self.identity[@"locale"] ?: @""];
    [stack addArrangedSubview:self.localeField];
    [self addHelp:@"locale" to:stack];
    [self addCatalogButton:@"Use region's language" to:stack action:@selector(chooseLanguage)];
    [stack addArrangedSubview:[self caption:@"Timezone"]];
    self.timezoneField = [self field:@"Timezone, e.g. America/New_York"
        value:self.identity[@"timezone"] ?: @""];
    [stack addArrangedSubview:self.timezoneField];
    [self addHelp:@"timezone" to:stack];
    [stack addArrangedSubview:[self caption:@"Carrier MCC-MNC"]];
    self.carrierField = [self field:@"Carrier MCC-MNC, e.g. 310-260"
        value:self.identity[@"carrierCode"] ?: @""];
    [stack addArrangedSubview:self.carrierField];
    [self addHelp:@"carrierCode" to:stack];
    [self addCatalogButton:@"Choose carrier" to:stack action:@selector(chooseCarrier)];
    [stack addArrangedSubview:[self caption:@"City"]];
    self.cityField = [self field:@"City"
        value:self.identity[@"city"] ?: @""];
    [stack addArrangedSubview:self.cityField];
    [self addCatalogButton:@"Choose city" to:stack action:@selector(chooseCity)];
    self.locationMapButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.locationMapButton setTitle:@"Choose location on map" forState:UIControlStateNormal];
    RBXStyleButton(self.locationMapButton,NO);
    [self.locationMapButton addTarget:self action:@selector(chooseLocationMap) forControlEvents:UIControlEventTouchUpInside];
    self.locationMapButton.accessibilityIdentifier=@"identity.locationMap";
    [stack addArrangedSubview:self.locationMapButton];
    [self addHelp:@"city" to:stack];
    stack = RBXFormSection(page, @"Device identifiers", nil);
    self.identifierStatusLabel = [self caption:@"Load saved values to review required identifiers."];
    [stack addArrangedSubview:self.identifierStatusLabel];
    [stack addArrangedSubview:[self caption:
        @"Review the generated UUIDs and UDID or enter values manually. Check consistency rejects invalid formats, model-incompatible identifiers and values used by another container. A generic model can omit IMEI; Zero + ATT denied uses an all-zero IDFA."]];
    NSArray *identifierDefinitions = @[
        @[@"serialNumber", @"Serial number"],
        @[@"udid", @"UDID"],
        @[@"imei1", @"IMEI"],
        @[@"wifiMac", @"Wi-Fi MAC"],
        @[@"btMac", @"Bluetooth MAC"],
        @[@"platformUUID", @"Platform UUID"],
        @[@"idfa", @"IDFA"],
        @[@"idfv", @"IDFV"],
        @[@"installId", @"Reddit install ID"],
        @[@"externalInstallationId", @"Reddit external installation ID"],
        @[@"mlb", @"Logic-board serial (MLB)"],
        @[@"uniqueChipId", @"Unique chip ID (ECID)"],
        @[@"bootTimeOffsetSeconds", @"Initial uptime (seconds)"],
        @[@"syntheticBootEpoch", @"Boot time (Unix seconds)"],
        @[@"installTimestampMs", @"Reddit install time (Unix milliseconds)"],
        @[@"latitude", @"Latitude"],
        @[@"longitude", @"Longitude"],
    ];
    for (NSArray *definition in identifierDefinitions) {
        NSString *key = definition[0];
        if (![self.appDescriptor[@"appType"] isEqual:@"reddit"] && [@[@"installId", @"externalInstallationId", @"installTimestampMs"] containsObject:key]) continue;
        [stack addArrangedSubview:[self caption:definition[1]]];
        UITextField *field = [self field:definition[1]
            value:self.identity[key] ?: @""];
        self.identifierFields[key] = field;
        [stack addArrangedSubview:field];
        [self addHelp:key to:stack];
    }

    stack = RBXFormSection(page, @"Hardware & software filled from the model",
        @"These linked values update together when you choose an iPhone, iOS or region. They are derived, not independent random values. A missing catalog value is shown as unavailable.");
    self.derivedIdentityLabel = [self caption:@"Load or automatically fill a profile to see its hardware and software values."];
    [stack addArrangedSubview:self.derivedIdentityLabel];

    if (self.simpleMode) {
        self.advancedButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.advancedButton setTitle:@"Show advanced groups" forState:UIControlStateNormal];
        RBXStyleButton(self.advancedButton, NO);
        [self.advancedButton addTarget:self action:@selector(toggleAdvancedGroups) forControlEvents:UIControlEventTouchUpInside];
        [page addArrangedSubview:self.advancedButton];
        self.advancedStack = [UIStackView new];
        self.advancedStack.axis = UILayoutConstraintAxisVertical;
        self.advancedStack.spacing = 20;
        page = self.advancedStack;
        [page addArrangedSubview:[self caption:@"Manual changes stay in this draft. Check consistency before saving."]];
    }
    if (!self.creationDraftToken.length) {
    stack = RBXFormSection(page, @"Isolation Sentinel", @"Runtime diagnostics for this container. Off by default. Results appear in Settings → Diagnostics. The observer reports findings without stopping an active session. A retained isolation alert blocks the next Open.");
    NSDictionary *sentinel = self.row[@"isolationSentinel"][@"settings"] ?: @{};
    self.sentinelSwitch = [UISwitch new];
    self.sentinelSwitch.on = [sentinel[@"enabled"] boolValue];
    self.sentinelSwitch.accessibilityLabel = @"Isolation Sentinel";
    [stack addArrangedSubview:self.sentinelSwitch];
    [stack addArrangedSubview:[self caption:@"Repeat interval (minutes, 1–1440). Default 15. Also runs after launch readiness and when returning to the clone. iOS may suspend periodic work in the background."]];
    self.sentinelInterval = [self field:@"15" value:[sentinel[@"intervalMinutes"] stringValue] ?: @"15"];
    self.sentinelInterval.keyboardType = UIKeyboardTypeNumberPad;
    [stack addArrangedSubview:self.sentinelInterval];
    [stack addArrangedSubview:[self caption:@"Optional clipboard write challenge. Off by default. Attempts an expiring local marker through the public pasteboard API. This changes the clipboard if blocking is broken; shared-clipboard compatibility skips the write."]];
    self.sentinelClipboardSwitch = [UISwitch new];
    self.sentinelClipboardSwitch.on = [sentinel[@"clipboardChallenge"] boolValue];
    self.sentinelClipboardSwitch.accessibilityLabel = @"Optional clipboard write challenge";
    [stack addArrangedSubview:self.sentinelClipboardSwitch];
    self.sentinelSaveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sentinelSaveButton setTitle:@"Save sentinel settings" forState:UIControlStateNormal];
    RBXStyleButton(self.sentinelSaveButton,NO);
    [self.sentinelSaveButton addTarget:self action:@selector(saveSentinelSettings) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.sentinelSaveButton];
    [stack addArrangedSubview:[self caption:@"Reopen this clone after enabling. Known sibling markers come from the SSH acceptance seed stage. Missing seeds show NOT RUN. A PASS covers the stated probes only; it cannot establish 100% isolation."]];
    }
    stack = RBXFormSection(page, @"Presentation", nil);
    [stack addArrangedSubview:[self caption:@"Device name"]];
    self.deviceNameField = [self field:@"Device name"
        value:@""];
    [stack addArrangedSubview:self.deviceNameField];
    [self addHelp:@"deviceName" to:stack];
    [stack addArrangedSubview:[self caption:
        @"These values belong to this container. Changes stay in this draft until saved."]];

    [stack addArrangedSubview:[self caption:@"IDFA posture"]];
    self.idfaControl = [[UISegmentedControl alloc]
        initWithItems:@[@"Random IDFA", @"Zero + ATT denied"]];
    self.idfaControl.selectedSegmentIndex =
        [self.identity[@"idfaPosture"] isEqualToString:@"zeroWithATTDenied"] ? 1 : 0;
    [stack addArrangedSubview:self.idfaControl];
    [self addHelp:@"idfaPosture" to:stack];
    [self.idfaControl addTarget:self action:@selector(idfaPostureChanged) forControlEvents:UIControlEventValueChanged];

    if ([self.appDescriptor[@"appType"] isEqual:@"reddit"]) {
    [stack addArrangedSubview:[self caption:@"Reddit font size"]];
    self.fontControl = [[UISegmentedControl alloc] initWithItems:@[@"16", @"17", @"19"]];
    NSInteger fontIndex = [@[@"16", @"17", @"19"]
        indexOfObject:self.identity[@"fontSize"] ?: @"17"];
    self.fontControl.selectedSegmentIndex =
        fontIndex == NSNotFound ? 1 : fontIndex;
    [stack addArrangedSubview:self.fontControl];
    [self addHelp:@"fontSize" to:stack];
    [self.fontControl addTarget:self action:@selector(choicesChanged) forControlEvents:UIControlEventValueChanged];
    }
    [stack addArrangedSubview:[self caption:@"Battery offset (%)"]];
    self.batteryField = [self field:@"Battery offset (-8 to +8)"
        value:self.identity[@"batteryOffsetPercent"] ?: @"0"];
    self.batteryField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    [stack addArrangedSubview:self.batteryField];
    [self addHelp:@"batteryOffsetPercent" to:stack];

    stack = RBXFormSection(page, @"Compatibility & isolation", nil);
    [stack addArrangedSubview:[self caption:
        @"Compatibility and isolation policies (exceptions are safer OFF; strict timing virtualization is safer ON)"]];
    NSDictionary *security = self.identity[@"security"] ?: @{};
    NSDictionary *labels = @{
        @"appAttest": @"Allow App Attest",
        @"deviceCheck": @"Allow DeviceCheck",
        @"localNetworking": @"Allow loopback connections",
        @"sensorAccess": @"Allow motion sensors",
        @"networkMetadata": @"Allow network metadata",
        @"thirdPartyNetwork": @"Allow third-party network SDKs",
        @"strictTiming": @"Enable strict timing virtualization",
        @"systemClipboard": @"Allow system clipboard (shared across profiles)",
    };
    for (NSString *key in @[@"appAttest", @"deviceCheck", @"localNetworking",
                             @"sensorAccess", @"networkMetadata",
                             @"thirdPartyNetwork", @"strictTiming", @"systemClipboard"]) {
        UILabel *label = [self caption:labels[key]];
        UISwitch *toggle = [UISwitch new];
        toggle.onTintColor = RBXAccentColor();
        toggle.accessibilityLabel = labels[key];
        [toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        toggle.on = [security[key] isEqualToString:@"enabled"];
        [toggle addTarget:self action:@selector(choicesChanged) forControlEvents:UIControlEventValueChanged];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionEqualSpacing;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 16;
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
        self.securitySwitches[key] = toggle;
        [stack addArrangedSubview:row];
        [self addHelp:key to:stack];
    }

    [stack addArrangedSubview:[self caption:@"System clipboard is blocked by default. Enable it only if login requires pasting a password or code; it exposes shared clipboard content/metadata to this profile. Disable afterward. RedditBox never clears your clipboard."]];
    stack = RBXFormSection(self.pageStack, @"Review & apply", nil);

    if ([self.identity[@"locked"] boolValue]) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = [NSString stringWithFormat:
            @"%@ Compatibility policy switches remain editable.",
            self.identity[@"lockReason"] ?: @""];
    }
    UIButton *check = [UIButton buttonWithType:UIButtonTypeSystem];
    [check setTitle:@"Check consistency" forState:UIControlStateNormal];
    RBXStyleButton(check, NO);
    [check addTarget:self action:@selector(checkConsistency)
      forControlEvents:UIControlEventTouchUpInside];
    self.checkButton = check;
    [stack addArrangedSubview:check];
    self.applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.applyButton setTitle:[self.identity[@"locked"] boolValue]
        ? @"Save compatibility policies" : @"Save changes"
        forState:UIControlStateNormal];
    RBXStyleButton(self.applyButton, YES);
    self.applyButton.enabled = YES;
    [self.applyButton addTarget:self action:@selector(applyIdentity)
                forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.applyButton];

    [self modeChanged];
    [self updateLocalWarning];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, RBXIdentityStateChanged,
        CFSTR("com.redditbox.launcherStateChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)saveSentinelSettings {
    if (self.pendingRequestId.length) return;
    NSString *text = self.sentinelInterval.text ?: @"";
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    NSInteger minutes = text.integerValue;
    if (!text.length || text.length > 4 || [text rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound || minutes < 1 || minutes > 1440) {
        self.statusLabel.text = @"Sentinel interval must be a whole number from 1 to 1440 minutes."; return;
    }
    self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:@"configureIsolationSentinel"
        values:@{@"container":self.row[@"id"] ?: @"",@"settings":@{@"enabled":@(self.sentinelSwitch.on),
            @"intervalMinutes":@(minutes),@"clipboardChallenge":@(self.sentinelClipboardSwitch.on)}}
        notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    [self refreshControls];
    self.statusLabel.textColor = self.pendingRequestId.length ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
    self.statusLabel.text = self.pendingRequestId.length ? @"Saving sentinel settings…" : @"Could not send sentinel settings.";
}

- (void)reloadIdentity { [self requestDraft:NO]; }
- (void)detectProxyRegion {
    if (!self.identityLoaded || self.pendingRequestId.length || [self.identity[@"locked"] boolValue]) return;
    self.validatedChoices = nil;
    self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:@"detectProxyRegion"
        values:@{@"container":self.row[@"id"] ?: @""} notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    [self modeChanged];
    self.statusLabel.textColor = self.pendingRequestId.length ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
    self.statusLabel.text = self.pendingRequestId.length ? @"Detecting region through proxy…" : @"Could not start lookup. Retry.";
}
- (void)randomFill { [self requestDraft:YES]; }
- (void)automaticFill { [self requestDraft:YES automatic:YES]; }
- (void)requestDraft:(BOOL)randomize {
    [self requestDraft:randomize automatic:NO];
}
- (void)requestDraft:(BOOL)randomize automatic:(BOOL)automatic {
    if (self.pendingRequestId.length || (randomize && (!self.identityLoaded || [self.identity[@"locked"] boolValue]))) return;
    self.validatedChoices = nil;
    self.pendingAutomaticFill = automatic;
    self.pendingAutomaticSecurity = automatic ? [self.choices[@"security"] copy] : nil;
    NSDictionary *selection = !randomize ? @{} : automatic ? @{@"automatic":@YES} :
        @{@"productType":self.productTypeField.text ?: @"", @"iosVersion":self.iosVersionField.text ?: @""};
    self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:randomize ? @"randomizeIdentityEditor" : @"loadIdentityEditor"
        values:[self creationScopedValues:@{@"container":self.row[@"id"] ?: @"", @"selection":selection}]
        notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    [self modeChanged];
    self.statusLabel.textColor = self.pendingRequestId.length ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
    self.statusLabel.text = self.pendingRequestId.length ? (self.creationDraftToken.length ? @"Preparing unsaved identity…" : automatic ? @"Verifying proxy and preparing automatic draft…" : randomize ? @"Preparing random draft for the selected model and iOS…" : @"Loading saved identity…") : @"Request could not be sent. The current draft was kept; try again.";
    if (!self.pendingRequestId.length) {
        self.pendingAutomaticFill = NO;
        self.pendingAutomaticSecurity = nil;
    }
}
- (void)populateDraft:(NSDictionary *)draft {
    NSDictionary *region = [draft[@"automaticRegion"] isKindOfClass:NSDictionary.class] ? draft[@"automaticRegion"] : nil;
    self.regionStatusLabel.text = region.count ? [NSString stringWithFormat:
        @"Automatic draft region: %@, %@. Time zone: %@. Verified through the %@ proxy. Language and carrier are suggestions; no profile changes have been saved.",
        region[@"city"] ?: @"city unavailable", region[@"country"] ?: @"country unavailable", region[@"timezone"] ?: @"unavailable",
        [region[@"proxySource"] isEqual:@"assigned"] ? @"assigned container" : @"selected device"] :
        (self.creationDraftToken.length ? @"Prepared proxy region. Carrier and language are suggestions. Editing these fields never changes the actual proxy." : @"Loaded draft region. Set from proxy performs a fresh lookup; changing fields does not change the proxy itself.");
    self.identity = draft;
    self.modelLabel.text = draft[@"marketingName"] ?: draft[@"productType"] ?: @"Choose a model";
    self.identityLoaded = YES;
    [self.applyButton setTitle:[draft[@"locked"] boolValue] ? @"Save compatibility policies" : @"Save changes" forState:UIControlStateNormal];
    self.modeControl.selectedSegmentIndex = 1;
    NSDictionary *fields = @{@"productType":self.productTypeField,@"iosVersion":self.iosVersionField,@"country":self.countryField,
        @"locale":self.localeField,@"timezone":self.timezoneField,@"carrierCode":self.carrierField,@"city":self.cityField,
        @"deviceName":self.deviceNameField,@"batteryOffsetPercent":self.batteryField};
    [fields enumerateKeysAndObjectsUsingBlock:^(NSString *key, UITextField *field, BOOL *stop) { field.text = [draft[key] isKindOfClass:NSString.class] ? draft[key] : @""; }];
    [self.identifierFields enumerateKeysAndObjectsUsingBlock:^(NSString *key, UITextField *field, BOOL *stop) { field.text = [draft[key] isKindOfClass:NSString.class] ? draft[key] : @""; }];
    self.idfaControl.selectedSegmentIndex = [draft[@"idfaPosture"] isEqual:@"zeroWithATTDenied"] ? 1 : 0;
    NSUInteger font = [@[@"16",@"17",@"19"] indexOfObject:draft[@"fontSize"] ?: @"17"];
    self.fontControl.selectedSegmentIndex = font == NSNotFound ? 1 : font;
    [self.securitySwitches enumerateKeysAndObjectsUsingBlock:^(NSString *key, UISwitch *toggle, BOOL *stop) { toggle.on = [draft[@"security"][key] isEqual:@"enabled"]; }];
    [self modeChanged];
    [self updateDerivedIdentity];
}

- (void)updateDerivedIdentity {
    NSDictionary *catalog = self.catalog, *model = catalog[@"models"][self.productTypeField.text ?: @""];
    NSDictionary *screen = model[@"screen"] ?: @{};
    NSString *country = self.countryField.text.uppercaseString ?: @"";
    NSString *sku = [model[@"modelBase"] length] && [catalog[@"regionSuffixes"][country] length] ?
        [model[@"modelBase"] stringByAppendingString:catalog[@"regionSuffixes"][country]] : @"Unavailable in catalog";
    self.derivedIdentityLabel.text = [NSString stringWithFormat:
        @"Model: %@\nRetail model number: %@\nHardware board: %@\nRegulatory model: %@\nChip / GPU: %@\nRAM: %@ bytes\nScreen: %@ × %@ pixels; scale %@; %@ Hz\niOS build: %@\nDarwin: %@\nDevice class: iPhone\nSIM report: Ready\nLanguage: %@\nApp device name: Apple;%@",
        model[@"marketingName"] ?: @"Unavailable", sku, model[@"hwModelStr"] ?: @"Unavailable",
        model[@"regulatoryModel"] ?: @"Unavailable", model[@"chip"] ?: @"Unavailable",
        model[@"ramBytes"] ?: @"Unavailable", screen[@"w"] ?: @"?", screen[@"h"] ?: @"?",
        screen[@"scale"] ?: @"?", screen[@"fps"] ?: @"?",
        catalog[@"iosBuilds"][self.iosVersionField.text ?: @""] ?: @"Unavailable",
        catalog[@"darwinReleases"][self.iosVersionField.text ?: @""] ?: @"Unavailable",
        [self.localeField.text componentsSeparatedByString:@"_"].firstObject ?: @"Unavailable",
        self.productTypeField.text ?: @"Unavailable"];
}

- (void)fillCoordinatesForSelectedCity {
    for (NSDictionary *city in self.catalog[@"countryCities"][self.countryField.text.uppercaseString ?: @""] ?: @[]) {
        if (![city[@"city"] isEqual:self.cityField.text]) continue;
        self.identifierFields[@"latitude"].text = [city[@"lat"] description] ?: @"";
        self.identifierFields[@"longitude"].text = [city[@"lon"] description] ?: @"";
        self.timezoneField.text = city[@"timezone"];
        break;
    }
}

- (void)choicesChanged {
    self.validatedChoices = nil;
    self.applyButton.enabled = NO;
    [self updateIdentifierStatus];
    [self updateDerivedIdentity];
    if (self.pendingRequestId.length) return;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"Values changed. Run Check consistency before applying.";
}

- (void)toggleAdvancedGroups {
    if (self.advancedStack.superview) {
        [self.pageStack removeArrangedSubview:self.advancedStack];
        [self.advancedStack removeFromSuperview];
        [self.advancedButton setTitle:@"Show advanced groups" forState:UIControlStateNormal];
    } else {
        NSUInteger index = [self.pageStack.arrangedSubviews indexOfObject:self.advancedButton];
        [self.pageStack insertArrangedSubview:self.advancedStack atIndex:index + 1];
        [self.advancedButton setTitle:@"Hide advanced groups" forState:UIControlStateNormal];
    }
}

- (NSDictionary *)catalog {
    NSData *data = [NSData dataWithContentsOfFile:RBXInstalledPath(@"/usr/share/redditbox/catalog.json")];
    id catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [catalog isKindOfClass:NSDictionary.class] ? catalog : @{};
}

- (void)addCatalogButton:(NSString *)title to:(UIStackView *)stack action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    RBXStyleButton(button, NO);
    button.enabled = self.identityLoaded && ![self.identity[@"locked"] boolValue];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.catalogButtons addObject:button];
    [stack addArrangedSubview:button];
}

- (void)choose:(NSString *)title options:(NSArray<NSDictionary *> *)options apply:(void (^)(NSString *))apply {
    [self choose:title options:options prepareDraft:NO apply:apply];
}

- (void)choose:(NSString *)title options:(NSArray<NSDictionary *> *)options prepareDraft:(BOOL)prepareDraft apply:(void (^)(NSString *))apply {
    if (!self.identityLoaded || self.pendingRequestId.length || [self.identity[@"locked"] boolValue]) return;
    if (!options.count) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"No supported choices are available for this selection in the installed catalog. Reload the identity or update the installed catalog package, then try again.";
        return;
    }
    NSString *selected = nil;
    for (NSDictionary *option in options) if ([option[@"selected"] boolValue]) { selected = option[@"value"]; break; }
    RBXCatalogPickerViewController *picker = [[RBXCatalogPickerViewController alloc]
        initWithTitle:title options:options selectedValue:selected selection:^(NSString *value) {
        // A picker can outlive the draft that opened it. Recheck before changing fields.
        if (!self.identityLoaded || self.pendingRequestId.length || [self.identity[@"locked"] boolValue]) return;
        NSString *previousModel = self.productTypeField.text;
        apply(value);
        [self choicesChanged];
        [self updateLocalWarning];
        // Set request/error status last; ordinary picker updates must not hide it.
        if (prepareDraft && ![previousModel isEqual:self.productTypeField.text]) [self randomFill];
    }];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    RBXStyleNavigation(navigation);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)chooseModel {
    NSDictionary *models = self.catalog[@"models"] ?: @{};
    NSArray *options=RBXScreenModelOptions(models,[self physicalScreenMetrics],self.productTypeField.text);
    [self choose:@"Model" options:options prepareDraft:YES apply:^(NSString *value) {
        if ([self.productTypeField.text isEqual:value]) return;
        self.productTypeField.text = value;
        self.modelLabel.text = models[value][@"marketingName"] ?: value;
        NSArray *versions = [models[value][@"iosVersions"] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [b compare:a options:NSNumericSearch]; }] ?: @[];
        if (![versions containsObject:self.iosVersionField.text]) self.iosVersionField.text = versions.firstObject ?: @"";
    }];
}

- (NSDictionary *)physicalScreenMetrics {
    UIScreen *screen=self.view.window.screen ?: UIScreen.mainScreen;
    CGSize pixels=screen.nativeBounds.size,points=screen.bounds.size;
    return @{@"nativeWidth":@(MIN(pixels.width,pixels.height)),@"nativeHeight":@(MAX(pixels.width,pixels.height)),
        @"logicalWidth":@(MIN(points.width,points.height)),@"logicalHeight":@(MAX(points.width,points.height)),
        @"scale":@(screen.scale),@"nativeScale":@(screen.nativeScale)};
}

- (void)chooseLocationMap {
    if (!self.identityLoaded||self.pendingRequestId.length||self.presentedViewController) return;
    NSDictionary *openingChoices=[self.choices copy];
    NSString *country=self.countryField.text.uppercaseString ?: @"";
    BOOL locked=[self.identity[@"locked"] boolValue];
    __weak typeof(self) weakSelf=self;
    RBXLocationPickerViewController *picker=[[RBXLocationPickerViewController alloc] initWithCatalog:self.catalog country:country
        latitude:self.identifierFields[@"latitude"].text ?: @"" longitude:self.identifierFields[@"longitude"].text ?: @""
        proxyCountry:self.identity[@"proxyCountry"] ?: @"" observedCountry:self.identity[@"observedProxyCountry"] ?: @""
        locked:locked selection:^(NSDictionary *location) {
        typeof(self) self=weakSelf;
        if (!self) return;
        if (!self.identityLoaded||self.pendingRequestId.length||[self.identity[@"locked"] boolValue]||
            ![openingChoices isEqual:self.choices]) {
            self.statusLabel.text=@"The identity changed while the map was open. Reopen the map to review its current values.";
            self.statusLabel.textColor=[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
            return;
        }
        self.cityField.text=location[@"city"]; self.timezoneField.text=location[@"timezone"];
        self.identifierFields[@"latitude"].text=location[@"latitude"];
        self.identifierFields[@"longitude"].text=location[@"longitude"];
        [self choicesChanged]; [self updateLocalWarning];
        self.regionStatusLabel.text=@"Map selection is in this draft only. Check consistency and Save to apply it. This does not change or verify the proxy exit.";
    }];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker]; RBXStyleNavigation(navigation);
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)showRequestedLocationMap {
    if (!self.openLocationMapWhenLoaded||!self.identityLoaded||self.pendingRequestId.length||self.presentedViewController||
        !self.view.window||self.navigationController.topViewController!=self) return;
    self.openLocationMapWhenLoaded=NO;
    [self chooseLocationMap];
}

- (void)chooseIOS {
    NSArray *versions = self.catalog[@"models"][self.productTypeField.text ?: @""][@"iosVersions"] ?: @[];
    NSMutableArray *options = [NSMutableArray array];
    for (NSString *value in [versions sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [b compare:a options:NSNumericSearch]; }]) [options addObject:@{@"title":value,@"value":value,@"subtitle":[NSString stringWithFormat:@"Build %@ · %@",self.catalog[@"iosBuilds"][value] ?: @"not listed",self.modelLabel.text ?: self.productTypeField.text],@"selected":@([value isEqual:self.iosVersionField.text])}];
    [self choose:@"iOS version" options:options apply:^(NSString *value) { self.iosVersionField.text = value; }];
}

- (void)chooseRegion {
    NSDictionary *catalog = self.catalog;
    NSMutableArray *options = [NSMutableArray array];
    for (NSString *value in [[catalog[@"countryLocales"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [options addObject:@{@"title":[NSString stringWithFormat:@"%@ · %@",RBXOperatorCountry(value),[NSLocale.currentLocale displayNameForKey:NSLocaleCountryCode value:value] ?: value],@"value":value,@"subtitle":value,@"selected":@([value isEqual:self.countryField.text.uppercaseString])}];
    }
    [self choose:@"Region must match proxy country" options:options apply:^(NSString *value) {
        self.countryField.text = value;
        self.localeField.text = catalog[@"countryLocales"][value] ?: @"";
        self.timezoneField.text = catalog[@"countryTimezones"][value] ?: @"";
        self.cityField.text = [catalog[@"countryCities"][value] firstObject][@"city"] ?: @"";
        [self fillCoordinatesForSelectedCity];
        NSDictionary *carrier = [catalog[@"carriers"][value] firstObject];
        self.carrierField.text = carrier ? [NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]] : @"";
    }];
}

- (void)chooseLanguage {
    NSString *locale = self.catalog[@"countryLocales"][self.countryField.text.uppercaseString ?: @""];
    [self choose:@"Supported language & region" options:locale ? @[@{@"title":[NSLocale.currentLocale displayNameForKey:NSLocaleIdentifier value:locale] ?: locale,@"value":locale,@"subtitle":@"Regional locale supported by this country’s catalog",@"selected":@([locale isEqual:self.localeField.text])}] : @[]
        apply:^(NSString *value) { self.localeField.text = value; }];
}

- (void)chooseCity {
    NSMutableArray *options = [NSMutableArray array];
    for (NSDictionary *city in self.catalog[@"countryCities"][self.countryField.text.uppercaseString ?: @""] ?: @[])
        [options addObject:@{@"title":city[@"city"], @"value":city[@"city"], @"subtitle":city[@"timezone"] ?: @"", @"group":[NSString stringWithFormat:@"%@ · %@",RBXOperatorCountry(self.countryField.text.uppercaseString),[NSLocale.currentLocale displayNameForKey:NSLocaleCountryCode value:self.countryField.text.uppercaseString] ?: self.countryField.text.uppercaseString], @"selected":@([city[@"city"] isEqual:self.cityField.text])}];
    [self choose:@"City" options:options apply:^(NSString *value) {
        self.cityField.text = value;
        [self fillCoordinatesForSelectedCity];
        for (NSDictionary *city in self.catalog[@"countryCities"][self.countryField.text.uppercaseString ?: @""] ?: @[])
            if ([city[@"city"] isEqual:value]) self.timezoneField.text = city[@"timezone"];
    }];
}

- (void)chooseCarrier {
    NSMutableArray *options = [NSMutableArray array];
    for (NSDictionary *carrier in self.catalog[@"carriers"][self.countryField.text.uppercaseString ?: @""] ?: @[]) {
        NSString *value = [NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]];
        [options addObject:@{@"title":carrier[@"name"] ?: @"Carrier", @"value":value,
            @"subtitle":[@"MCC–MNC · " stringByAppendingString:value],
            @"group":[NSString stringWithFormat:@"%@ · %@",RBXOperatorCountry(self.countryField.text.uppercaseString),[NSLocale.currentLocale displayNameForKey:NSLocaleCountryCode value:self.countryField.text.uppercaseString] ?: self.countryField.text.uppercaseString],
            @"selected":@([value isEqual:[self.carrierField.text stringByReplacingOccurrencesOfString:@":" withString:@"-"]])}];
    }
    [self choose:@"Carrier" options:options apply:^(NSString *value) { self.carrierField.text = value; }];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, NULL, NULL);
}

- (void)requestsDidBecomeActive:(NSNotification *)notification {
    [self loadResult];
}

- (NSDictionary *)creationScopedValues:(NSDictionary *)values {
    if (!self.creationDraftToken.length) return values;
    NSMutableDictionary *scoped = values.mutableCopy;
    scoped[@"creationDraftToken"] = self.creationDraftToken;
    scoped[@"creationDraftRevision"] = self.creationDraftRevision ?: @0;
    return scoped;
}

- (NSString *)requestOwner {
    if (self.creationDraftToken.length) return [@"creation-identity:" stringByAppendingString:self.creationDraftToken];
    return RBXAppScopedPreferenceKey([@"identity:" stringByAppendingString:self.row[@"id"] ?: @""], self.appDescriptor);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.pendingRequestId = [RBXLauncherIPC pendingRequestsForOwner:
        self.requestOwner].firstObject[@"requestId"];
    if (!self.pendingRequestId.length && !self.identityLoaded) [self reloadIdentity];
    else [self loadResult];
    if (self.focusRegionOnAppear) {
        self.focusRegionOnAppear = NO;
        self.openLocationMapWhenLoaded = YES;
        [self.view layoutIfNeeded];
        [self.identityScroll scrollRectToVisible:[self.regionSection convertRect:self.regionSection.bounds toView:self.identityScroll] animated:NO];
    }
    [self showRequestedLocationMap];
}

- (void)modeChanged {
    [self choicesChanged];
    [self refreshControls];
}

- (void)editingModeChanged {
    // This is a presentation choice. Only Fill automatically requests new values.
    [self refreshControls];
}

- (void)idfaPostureChanged {
    if ([self.identity[@"locked"] boolValue]) {
        self.idfaControl.selectedSegmentIndex = [self.identity[@"idfaPosture"] isEqual:@"zeroWithATTDenied"] ? 1 : 0;
        [self refreshControls];
        return;
    }
    if (!self.identityLoaded || self.pendingRequestId.length) return;
    [self refreshControls];
    [self choicesChanged];
}

- (NSArray<NSString *> *)missingRequiredIdentifiers {
    NSDictionary *labels = @{@"serialNumber":@"Serial number", @"udid":@"UDID", @"wifiMac":@"Wi-Fi MAC",
        @"btMac":@"Bluetooth MAC", @"platformUUID":@"Platform UUID", @"idfa":@"IDFA", @"idfv":@"IDFV",
        @"installId":@"Reddit install ID", @"externalInstallationId":@"Reddit external installation ID"};
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *key in @[@"serialNumber", @"udid", @"wifiMac", @"btMac", @"platformUUID", @"idfa", @"idfv", @"installId", @"externalInstallationId"]) {
        UITextField *field = self.identifierFields[key];
        if (field && ![field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
            [missing addObject:labels[key]];
    }
    for (NSString *key in RBXAdditionalIdentityFields()) {
        UITextField *field = self.identifierFields[key];
        if (field && ![field.text length]) [missing addObject:field.placeholder ?: key];
    }
    return missing;
}

- (void)updateIdentifierStatus {
    if (!self.identityLoaded) {
        self.identifierStatusLabel.text = @"Load saved values to review required identifiers.";
        self.identifierStatusLabel.textColor = UIColor.secondaryLabelColor;
        return;
    }
    NSArray *missing = self.missingRequiredIdentifiers;
    NSString *recovery = [self.identity[@"locked"] boolValue] ?
        @"This identity is locked. Reload its private draft or create a new container; compatibility-policy switches remain editable." :
        @"Fill automatically or enter them manually before saving.";
    self.identifierStatusLabel.text = missing.count ? [NSString stringWithFormat:
        @"Missing required identifiers: %@. %@", [missing componentsJoinedByString:@", "], recovery] :
        @"Required identifiers are filled. Check consistency validates their formats and uniqueness. Zero IDFA with ATT denied and a blank generic-model IMEI are intentional.";
    self.identifierStatusLabel.textColor = missing.count ? [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1] : UIColor.secondaryLabelColor;
}

// Updating request availability must not discard the result of a successful Check.
- (void)refreshControls {
    self.locationMapButton.enabled=self.identityLoaded&&!self.pendingRequestId.length;
    BOOL locked = [self.identity[@"locked"] boolValue];
    BOOL ready = self.identityLoaded && !self.pendingRequestId.length;
    BOOL manual = ready && !locked;
    self.randomButton.hidden = self.modeControl.selectedSegmentIndex != 0;
    if (self.identityLoaded && self.modeControl.selectedSegmentIndex == 1 && self.advancedStack && !self.advancedStack.superview)
        [self toggleAdvancedGroups];
    self.applyButton.enabled = ready && (locked || !self.missingRequiredIdentifiers.count) && RBXIdentityReviewCanApply(self.choices, self.validatedChoices,
        NO, [self.identity[@"proxyMismatch"] boolValue]);
    self.sentinelSaveButton.enabled = !self.pendingRequestId.length;
    self.sentinelSwitch.enabled = !self.pendingRequestId.length;
    self.sentinelClipboardSwitch.enabled = !self.pendingRequestId.length;
    self.sentinelInterval.enabled = !self.pendingRequestId.length;
    self.modeControl.enabled = manual;
    self.countryField.enabled = manual;
    self.countryField.alpha = manual ? 1.0 : 0.55;
    self.randomButton.enabled = manual;
    self.checkButton.enabled = ready;
    self.navigationItem.rightBarButtonItem.enabled = !self.pendingRequestId.length;
    for (UISwitch *toggle in self.securitySwitches.allValues) toggle.enabled = ready;
    for (UIButton *button in self.catalogButtons) button.enabled = manual;
    self.idfaControl.enabled = manual;
    self.fontControl.enabled = manual;
    self.idfaControl.alpha = manual ? 1.0 : 0.55;
    self.fontControl.alpha = manual ? 1.0 : 0.55;
    for (UITextField *field in @[
        self.productTypeField, self.iosVersionField, self.localeField,
        self.timezoneField, self.carrierField, self.cityField,
        self.deviceNameField, self.batteryField]) {
        field.enabled = manual;
        field.alpha = manual ? 1.0 : 0.55;
    }
    [self.identifierFields enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, UITextField *field, BOOL *stop) {
            field.enabled = manual;
            field.alpha = manual ? 1.0 : 0.55;
        }];
    if (manual && self.idfaControl.selectedSegmentIndex == 1) {
        // Denied ATT derives zero in the backend; display that exact value before review.
        UITextField *idfa = self.identifierFields[@"idfa"];
        idfa.text = @"00000000-0000-0000-0000-000000000000";
        idfa.enabled = NO;
        idfa.alpha = 1.0;
    }
    [self updateIdentifierStatus];
}

- (void)updateLocalWarning {
    if (self.pendingRequestId.length) return;
    if (!self.identityLoaded) {
        self.statusLabel.text = self.pendingRequestId.length ? @"Loading identity details…" : @"Identity details are not loaded. Tap Reload; an empty form cannot be saved.";
        self.statusLabel.textColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
        return;
    }
    if ([self.identity[@"locked"] boolValue]) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = [NSString stringWithFormat:
            @"Identity is locked after first use. Create a new container to choose another model, iOS version, or identity. %@ Compatibility policy switches remain editable.",
            self.identity[@"lockReason"] ?: @""];
        return;
    }
    NSString *country = self.countryField.text.uppercaseString;
    NSString *proxyCountry = [self.identity[@"proxyCountry"] uppercaseString];
    if ([self.identity[@"proxyMismatch"] boolValue]) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = [NSString stringWithFormat:
            @"✕ Live proxy exit is %@ but this profile requires %@. Fix or rotate the proxy; launch remains blocked.",
            self.identity[@"observedProxyCountry"] ?: @"unknown",
            proxyCountry ?: @"unknown"];
    } else if ([self.identity[@"proxyAssigned"] boolValue] && country.length && proxyCountry.length &&
        ![country isEqualToString:proxyCountry]) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = [NSString stringWithFormat:
            @"✕ Configured proxy country is %@ but identity requests %@. This will be blocked.",
            proxyCountry, country];
    } else {
        self.statusLabel.textColor = UIColor.secondaryLabelColor;
        self.statusLabel.text = @"Run Check consistency before applying.";
    }
}

- (NSDictionary *)choices {
    NSMutableDictionary *security = [NSMutableDictionary dictionary];
    [self.securitySwitches enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, UISwitch *toggle, BOOL *stop) {
            security[key] = @(toggle.isOn);
        }];
    NSMutableDictionary *result = [@{
        // Generation finishes before review. Check/Save always use the displayed values.
        @"mode": @"manual",
        @"productType": self.productTypeField.text ?: @"",
        @"iosVersion": self.iosVersionField.text ?: @"",
        @"country": self.countryField.text.uppercaseString ?: @"",
        @"locale": self.localeField.text ?: @"",
        @"timezone": self.timezoneField.text ?: @"",
        @"carrierCode": self.carrierField.text ?: @"",
        @"city": self.cityField.text ?: @"",
        @"deviceName": self.deviceNameField.text ?: @"",
        @"idfaPosture": self.idfaControl.selectedSegmentIndex == 1
            ? @"zeroWithATTDenied" : @"random",
        @"fontSize": [self.fontControl titleForSegmentAtIndex:
            self.fontControl.selectedSegmentIndex] ?: @"17",
        @"batteryOffsetPercent": self.batteryField.text ?: @"0",
        @"securityOnly": @([self.identity[@"locked"] boolValue]),
        @"security": security,
    } mutableCopy];
    [self.identifierFields enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, UITextField *field, BOOL *stop) {
            result[key] = field.text ?: @"";
        }];
    return result;
}

- (void)checkConsistency {
    if (!self.identityLoaded) { [self updateLocalWarning]; return; }
    if (self.pendingRequestId.length) { [self loadResult]; return; }
    self.applyButton.enabled = NO;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"Checking model, runtime, geo, carrier and proxy…";
    self.validatedChoices = nil;
    self.pendingChoices = self.choices;
    self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:
        @"previewIdentity" values:[self creationScopedValues:@{
            @"container": self.row[@"id"] ?: @"",
            @"choices": self.pendingChoices,
        }] notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    [self refreshControls];
    if (!self.pendingRequestId.length) {
        self.applyButton.enabled = NO;
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = @"The consistency request could not be sent. Try again.";
    }
}

- (void)applyIdentity {
    if (self.pendingRequestId.length) { [self loadResult]; return; }
    if (!self.identityLoaded || (![self.identity[@"locked"] boolValue] && self.missingRequiredIdentifiers.count) || !RBXIdentityReviewCanApply(self.choices, self.validatedChoices,
        NO, [self.identity[@"proxyMismatch"] boolValue])) {
        self.statusLabel.text = @"Run Check consistency for these values before applying.";
        self.applyButton.enabled = NO;
        return;
    }
    BOOL securityOnly = [self.identity[@"locked"] boolValue];
    NSDictionary *reviewedChoices = [self.validatedChoices copy];
    UIAlertController *confirmation = [UIAlertController alertControllerWithTitle:
        self.creationDraftToken.length ? @"Use these draft values?" : securityOnly ? @"Apply compatibility policies?" : @"Apply this identity?"
        message:self.creationDraftToken.length ? @"These values will update only the preview. Return to New container and tap Create when you are ready." : securityOnly
            ? @"Changing these exceptions can weaken isolation. RedditBox will close traffic, validate the profile, and rebuild only if entitlements changed."
            : @"RedditBox will close traffic, validate the complete fingerprint, rebuild the hidden clone, and leave it blocked. Re-share/re-adopt the rebuilt IPA in MDM before opening."
        preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"Apply"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (!self.identityLoaded || (![self.identity[@"locked"] boolValue] && self.missingRequiredIdentifiers.count) || !RBXIdentityReviewCanApply(self.choices, reviewedChoices,
                self.pendingRequestId.length > 0, [self.identity[@"proxyMismatch"] boolValue]) ||
                ![self.validatedChoices isEqual:reviewedChoices]) {
                self.applyButton.enabled = NO;
                self.statusLabel.text = @"Values changed after review. Run Check consistency again before applying.";
                return;
            }
            self.applyButton.enabled = NO;
            self.statusLabel.textColor = UIColor.secondaryLabelColor;
            self.statusLabel.text = @"Applying identity safely…";
            self.pendingRequestId = [RBXLauncherIPC sendActionReturningRequestId:
                @"applyIdentity" values:[self creationScopedValues:@{
                    @"container": self.row[@"id"] ?: @"",
                    @"choices": reviewedChoices,
                }] notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
            [self refreshControls];
            if (!self.pendingRequestId.length) {
                self.statusLabel.textColor = UIColor.systemRedColor;
                self.statusLabel.text = @"The identity request could not be sent. Try again.";
            }
        }]];
    [self presentViewController:confirmation animated:YES completion:nil];
}

- (void)loadResult {
    if (!self.pendingRequestId.length) return;
    self.applyButton.enabled = NO;
    NSDictionary *result = [RBXLauncherIPC requestResultForId:self.pendingRequestId];
    if (!result) {
        self.statusLabel.text = @"Waiting for the daemon to complete this identity request…";
        return;
    }
    if (!self.view.window || self.navigationController.topViewController != self) return;
    if (self.presentedViewController) {
        // Darwin notification may arrive before a picker/confirmation finishes dismissing.
        // Keep the durable receipt pending and retry only while this editor is visible.
        if (!self.resultRetryScheduled) {
            self.resultRetryScheduled = YES;
            NSString *requestID = self.pendingRequestId;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                strongSelf.resultRetryScheduled = NO;
                if ([strongSelf.pendingRequestId isEqual:requestID]) [strongSelf loadResult];
            });
        }
        return;
    }
    if ([result[@"action"] isEqual:@"detectProxyRegion"]) {
        [RBXLauncherIPC finishObservingRequestId:self.pendingRequestId owner:self.requestOwner];
        self.pendingRequestId = nil;
        NSDictionary *region = result[@"details"];
        if ([result[@"ok"] boolValue]) {
            self.countryField.text = region[@"country"];
            self.localeField.text = region[@"locale"];
            self.timezoneField.text = region[@"timezone"];
            self.carrierField.text = region[@"carrierCode"];
            self.cityField.text = region[@"city"];
            [self fillCoordinatesForSelectedCity];
            [self updateDerivedIdentity];
            self.regionStatusLabel.text = [NSString stringWithFormat:
                @"Last lookup via %@ proxy: IP location estimate %@, %@.\nProfile city: %@ (%@). Time zone: %@ (%@).\nSuggested carrier: %@; language: %@.\nNetwork owner: %@. This is not a detected SIM carrier. The cloud still controls proxy assignment.",
                [region[@"proxySource"] isEqual:@"assigned"] ? @"Assigned" : @"Selected device",
                [region[@"observedCity"] length] ? region[@"observedCity"] : @"city unavailable", region[@"country"],
                region[@"city"], [region[@"citySource"] isEqual:@"ip-geolocation"] ? @"IP estimate" : @"catalog suggestion",
                region[@"timezone"], [region[@"timezoneSource"] isEqual:@"ip-geolocation"] ? @"IP estimate" : @"catalog suggestion",
                region[@"carrierName"], region[@"locale"], [region[@"networkName"] length] ? region[@"networkName"] : @"unavailable"];
        }
        [self modeChanged];
        self.statusLabel.text = [result[@"ok"] boolValue] ? @"Region filled in draft. Device identifiers were kept. Check and Save changes." : result[@"message"];
        self.statusLabel.textColor = [result[@"ok"] boolValue] ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
        return;
    }
    if ([result[@"action"] isEqual:@"configureIsolationSentinel"]) {
        [RBXLauncherIPC finishObservingRequestId:self.pendingRequestId owner:self.requestOwner];
        self.pendingRequestId = nil;
        [self refreshControls];
        self.statusLabel.text = result[@"message"];
        self.statusLabel.textColor = [result[@"ok"] boolValue] ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
        return;
    }
    if ([@[@"loadIdentityEditor", @"randomizeIdentityEditor"] containsObject:result[@"action"]]) {
        if (self.creationDraftToken.length && [result[@"ok"] boolValue] &&
            [result[@"details"][@"creationDraftToken"] isEqual:self.creationDraftToken])
            self.creationDraftRevision = result[@"details"][@"creationDraftRevision"];
        NSString *request = self.pendingRequestId;
        [RBXLauncherIPC finishObservingRequestId:request owner:self.requestOwner];
        self.pendingRequestId = nil;
        NSError *error = nil;
        NSDictionary *draft = [result[@"ok"] boolValue] ? [RBXSecureConfig identityEditorDraftForRequestID:request container:self.row[@"id"] error:&error] : nil;
        BOOL automatic = self.pendingAutomaticFill || [draft[@"draftSource"] isEqual:@"automatic"];
        NSDictionary *security = self.pendingAutomaticSecurity;
        self.pendingAutomaticFill = NO;
        self.pendingAutomaticSecurity = nil;
        if (draft) {
            [self populateDraft:draft];
            if (automatic && security) for (NSString *key in self.securitySwitches) self.securitySwitches[key].on = [security[key] boolValue];
            [self refreshControls];
            self.statusLabel.text = automatic ? @"Automatic draft prepared. Review or change the fields, then Check consistency and Save. Nothing has been saved." :
                [result[@"action"] isEqual:@"randomizeIdentityEditor"] ? @"Matching draft filled for the selected model and iOS. Review, check, then save." : @"Saved values loaded. Edit manually or fill automatically, then check and save.";
            self.statusLabel.textColor = UIColor.secondaryLabelColor;
            if ([draft[@"locked"] boolValue]) [self updateLocalWarning];
            [self showRequestedLocationMap];
        } else {
            [self modeChanged];
            NSString *message = error.localizedDescription ?: ([result[@"ok"] boolValue] ? @"The private draft is unavailable." : result[@"message"]) ?: @"Try again.";
            self.statusLabel.text = automatic ? [NSString stringWithFormat:@"Automatic fill failed: %@ Previous draft kept. Nothing was saved.", message] :
                [NSString stringWithFormat:@"Could not load identity: %@", message];
            self.statusLabel.textColor = UIColor.systemRedColor;
        }
        return;
    }
    if (self.creationDraftToken.length && [result[@"ok"] boolValue] &&
        [result[@"details"][@"creationDraftToken"] isEqual:self.creationDraftToken])
        self.creationDraftRevision = result[@"details"][@"creationDraftRevision"];
    [RBXLauncherIPC finishObservingRequestId:self.pendingRequestId owner:self.requestOwner];
    self.pendingRequestId = [RBXLauncherIPC pendingRequestsForOwner:
        self.requestOwner].firstObject[@"requestId"];
    BOOL ok = [result[@"ok"] boolValue];
    NSDictionary *details = [result[@"details"] isKindOfClass:NSDictionary.class]
        ? result[@"details"] : @{};
    self.validatedChoices = ok && ![details[@"applied"] boolValue] ? self.pendingChoices : nil;
    self.pendingChoices = nil;
    [self refreshControls];
    self.statusLabel.textColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
    NSDictionary *summary = [details[@"summary"] isKindOfClass:[NSDictionary class]]
        ? details[@"summary"] : @{};
    NSString *summaryText = summary.count ? [NSString stringWithFormat:
        @"\n%@ • iOS %@ • %@ • %@ • %@",
        summary[@"device"] ?: @"",
        summary[@"iosVersion"] ?: @"",
        summary[@"country"] ?: @"",
        summary[@"carrier"] ?: @"",
        summary[@"city"] ?: @""] : @"";
    self.statusLabel.text = [NSString stringWithFormat:@"%@ %@%@",
        ok ? @"PASS" : @"FAIL", RBXOperatorMessage(result[@"message"] ?: @"Identity check finished"),
        summaryText];
    if (!ok && self.simpleMode && !self.advancedStack.superview)
        [self.advancedButton setTitle:RBXOperatorText(@"advanced") forState:UIControlStateNormal];
    [self refreshControls];
    if (ok && [details[@"applied"] boolValue]) {
        UIAlertController *done = [UIAlertController alertControllerWithTitle:
            self.creationDraftToken.length ? @"Draft saved" : @"Identity applied" message:
            (self.creationDraftToken.length ? @"Your preview is updated. No container exists yet. Review it and tap Create on the previous screen." : [self.identity[@"locked"] boolValue]
                ? @"Compatibility policies are saved. If App Attest entitlement changed, re-share the IPA and let MDM adopt the rebuild."
                : @"The coherent identity is saved. Re-share the clone IPA and let MDM adopt the rebuilt app before opening it.")
            preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"Done"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [self.navigationController popViewControllerAnimated:YES];
            }]];
        [self presentViewController:done animated:YES completion:nil];
    }
}

@end
