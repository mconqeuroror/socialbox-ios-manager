#import "RBXHTTPProxy.h"
#import "RBXProxyLibrary.h"
#import "RBXSetupChecklist.h"
#import "RBXLicenseViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXDiagnosticsViewController.h"
#import "RBXIsolationViewController.h"
#import "RBXAppearance.h"
#import "RBXCloudVaultViewController.h"
#import "RBXWorkspaceNavigation.h"
#import "RBXProfileMetadata.h"
#import "RBXSettingsViewController.h"
#import "RBXLauncherIPC.h"
#import "RBXSecureConfig.h"
#import "RBXMDMExporter.h"
#import "RBXOperatorWording.h"
#import "RBXAppScope.h"
#import "RBXAppSetupStatus.h"
#import "RBXCreationDefaults.h"
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const RBXLauncherStatePath =
    @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist";
static NSString *const RBXAppVersionPrefsPath =
    @"/var/mobile/Library/Preferences/com.redditbox.appversion.plist";

// Presentation only: saved configuration and historical sync receipts are not
// live connectivity evidence. License color uses the existing freshness guard.
static NSDictionary *RBXSettingsStatusPresentation(NSDictionary *snapshot, NSTimeInterval now) {
    NSDictionary *state = RBXSetupDictionary(snapshot);
    NSDictionary *license = RBXLicensePresentationState(state,now);
    NSURLComponents *server = [NSURLComponents componentsWithString:license[@"serverURL"] ?: @""];
    BOOL configured = [server.scheme.lowercaseString isEqual:@"https"] && server.host.length &&
        !server.user.length && !server.password.length;
    NSDictionary *cloud = RBXSetupDictionary(state[@"cloud"]);
    BOOL timedReceipt = RBXLicensePresentationNumber(cloud[@"updatedAt"]) &&
        [cloud[@"updatedAt"] doubleValue] > 0 && [cloud[@"updatedAt"] doubleValue] <= now &&
        RBXLicensePresentationFlag(cloud[@"ok"]);
    // A receipt for a previous server must not describe the current server.
    BOOL sameServer = configured && [cloud[@"serverHost"] isKindOfClass:NSString.class] &&
        [cloud[@"serverHost"] caseInsensitiveCompare:server.host] == NSOrderedSame;
    BOOL active = [license[@"unlocked"] boolValue];
    return @{@"serverConfigured":@(configured),
        @"serverTitle":configured ? server.host : @"Setup required",
        @"cloudReceiptAt":timedReceipt && sameServer ? cloud[@"updatedAt"] : @0,
        @"cloudReceiptOK":@(timedReceipt && sameServer && [cloud[@"ok"] boolValue]),
        @"licenseActive":@(active),
        @"licenseTitle":active ? ([license[@"offlineGrace"] boolValue] ? @"Offline grace" : @"Activated") : @"Needs attention",
        @"licenseDetail":active ? ([license[@"offlineGrace"] boolValue] ? @"Signed offline access is valid. This does not verify a cloud connection." : @"Signed activation is currently valid.") : (license[@"reason"] ?: @"Open Account & license to finish activation.")};
}

// Copy while holding coordinated access to a document-provider URL. Create the
// private staging file with restrictive permissions before writing any bytes.
static NSString *RBXStageSourceIPA(NSURL *url, NSDictionary *descriptor, NSError **error) {
    if (!RBXAppDescriptorIsRegistered(descriptor)) {
        if (error) *error = [NSError errorWithDomain:@"RBXAppSource" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"This app type is not registered. No source was staged."}];
        return nil;
    }
    NSString *sourceInbox = descriptor[@"sourceInboxPath"];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:sourceInbox withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error]) return nil;
    struct stat inbox;
    if (lstat(sourceInbox.fileSystemRepresentation, &inbox) != 0 ||
        !S_ISDIR(inbox.st_mode) || inbox.st_uid != getuid() ||
        chmod(sourceInbox.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES
            userInfo:@{NSLocalizedDescriptionKey: @"The private source inbox is not accessible. Reinstall the package to repair its permissions."}];
        return nil;
    }
    NSString *path = [sourceInbox stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"ipa"]];
    int input = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    struct stat source;
    if (input < 0 || fstat(input, &source) != 0 || !S_ISREG(source.st_mode)) {
        int failure = input < 0 ? errno : EINVAL;
        if (input >= 0) close(input);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure
            userInfo:@{NSLocalizedDescriptionKey: @"The selected IPA could not be read as a regular file."}];
        return nil;
    }
    int output = open(path.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int failure = output < 0 ? errno : 0;
    char buffer[131072];
    while (!failure) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { failure = errno; break; }
        if (!count) break;
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, count - offset);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { failure = written < 0 ? errno : EIO; break; }
            offset += written;
        }
    }
    if (!failure && fsync(output) != 0) failure = errno;
    close(input);
    if (output >= 0 && close(output) != 0 && !failure) failure = errno;
    if (failure) {
        if (output >= 0) [files removeItemAtPath:path error:nil];
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure
            userInfo:@{NSLocalizedDescriptionKey: @"Could not copy the IPA into private storage. Check free space and try again."}];
        return nil;
    }
    return path;
}

@interface RBXSettingsViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSDictionary *appDescriptor;
@property(nonatomic) BOOL wizardMode;
@property(nonatomic) BOOL proxyMode;
@property(nonatomic, strong) UIStackView *advancedProxyFields;
@property(nonatomic, strong) UIStackView *generalAdvancedFields;
@property(nonatomic, strong) UIButton *advancedProxyButton;
@property(nonatomic, copy) NSString *requestOwner;
@property(nonatomic, strong) UITextField *proxyField;
@property(nonatomic, strong) UITextField *rotationField;
@property(nonatomic, strong) UITextField *headerField;
@property(nonatomic, strong) UITextField *authorizationField;
@property(nonatomic, strong) UISegmentedControl *methodControl;
@property(nonatomic, strong) UILabel *sourceLabel;
@property(nonatomic, strong) UILabel *testLabel;
@property(nonatomic, strong) UILabel *redditSourceLabel;
@property(nonatomic, strong) UILabel *firewallSetupLabel;
@property(nonatomic, strong) UIStackView *setupRows;
@property(nonatomic, strong) UIStackView *setupEvidenceRows;
@property(nonatomic, strong) UILabel *serverStatusLabel;
@property(nonatomic, strong) UILabel *serverDetailLabel;
@property(nonatomic, strong) UILabel *licenseStatusLabel;
@property(nonatomic, strong) UILabel *licenseDetailLabel;
@property(nonatomic, strong) UIView *workspaceBackground;
@property(nonatomic, copy) NSArray *renderedSetupRows;
@property(nonatomic, strong) NSTimer *setupTimer;
@property(nonatomic, strong) UIButton *sourceImportButton;
@property(nonatomic, copy) NSString *sourceImportRequestId;
@property(nonatomic, copy) NSString *sourceImportLocalError;
@property(nonatomic) BOOL stagingSourceImport;
@property(nonatomic, copy) NSDictionary *sourceImportDescriptor;
@property(nonatomic, strong) UIButton *testButton;
@property(nonatomic, strong) UITextField *cloudServerField;
@property(nonatomic, strong) UITextField *pairingCodeField;
@property(nonatomic, strong) UILabel *cloudStatusLabel;
@property(nonatomic, strong) UITextField *accessKeyField;
@property(nonatomic) NSTimeInterval loadedConfigurationAt;
@property(nonatomic, strong) UITextField *defaultCountryField;
@property(nonatomic, copy) NSDictionary *testResult;
@property(nonatomic, copy) NSDictionary *cloudResult;
@property(nonatomic, strong) UITextField *latestVersionField;
@property(nonatomic, strong) UITextField *versionIntervalField;
- (void)refreshStatus;
@end

static void RBXSettingsStateChanged(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    RBXSettingsViewController *controller =
        (__bridge RBXSettingsViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller refreshStatus];
    });
}

@implementation RBXSettingsViewController

- (instancetype)initWithWizardMode:(BOOL)wizardMode { return [self initWithAppType:@"reddit" wizardMode:wizardMode]; }
- (instancetype)initWithProxyMode:(BOOL)proxyMode { return [self initWithAppType:@"reddit" proxyMode:proxyMode]; }
- (instancetype)initWithAppType:(NSString *)appType wizardMode:(BOOL)wizardMode {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor) return nil;
    self = [super initWithNibName:nil bundle:nil];
    if (self) { _wizardMode = wizardMode; _appDescriptor = descriptor; _sourceImportDescriptor = descriptor;
        _requestOwner = RBXAppScopedPreferenceKey(@"settings", descriptor); }
    return self;
}
- (instancetype)initWithAppType:(NSString *)appType proxyMode:(BOOL)proxyMode {
    self = [self initWithAppType:appType wizardMode:NO];
    if (self) { _proxyMode = proxyMode; _requestOwner = RBXAppScopedPreferenceKey(proxyMode ? @"proxy-settings" : @"settings", self.appDescriptor); }
    return self;
}
- (NSString *)appText:(NSString *)text { return [text stringByReplacingOccurrencesOfString:@"Reddit" withString:self.appDescriptor[@"displayName"]]; }

- (void)openCloudVault { [self.navigationController pushViewController:[[RBXCloudVaultViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES]; }

- (void)changeAppearance:(UISegmentedControl *)control {
    [NSUserDefaults.standardUserDefaults setInteger:control.selectedSegmentIndex forKey:@"RBXAppearance"];
    self.view.window.overrideUserInterfaceStyle = RBXPreferredAppearance();
}

- (void)toggleAdvancedProxy {
    self.advancedProxyFields.hidden = !self.advancedProxyFields.hidden;
    [self.advancedProxyButton setTitle:self.advancedProxyFields.hidden ? @"Advanced options" : @"Hide advanced options"
        forState:UIControlStateNormal];
}

- (void)toggleGeneralAdvanced:(UIButton *)button {
    self.generalAdvancedFields.hidden = !self.generalAdvancedFields.hidden;
    [button setTitle:self.generalAdvancedFields.hidden ? @"Advanced & evidence" : @"Hide advanced details" forState:UIControlStateNormal];
}

- (void)openDiagnostics {
    [self.navigationController pushViewController:[[RBXIsolationViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
}

- (void)openAccount {
    [self performSetupAction:@"license"];
}

- (UITextField *)field:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.secureTextEntry = secure;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    RBXStyleField(field);
    return field;
}

- (UILabel *)caption:(NSString *)text {
    return RBXLabel(text, UIFontTextStyleFootnote, YES);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [RBXLauncherIPC migrateLegacyRequestStateIfNeeded];
    self.sourceImportRequestId = [NSUserDefaults.standardUserDefaults stringForKey:RBXAppSourceImportRequestKey(self.appDescriptor)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(requestsDidBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    self.navigationItem.title = self.wizardMode ? @"Set up SocialBox" : (self.proxyMode ? @"Proxies" : @"Settings");
    self.view.backgroundColor = RBXCanvasColor();
    self.workspaceBackground = RBXWorkspaceBackgroundView(self.traitCollection);
    self.workspaceBackground.frame = self.view.bounds;
    self.workspaceBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.workspaceBackground atIndex:0];
    self.navigationItem.largeTitleDisplayMode = self.wizardMode ? UINavigationItemLargeTitleDisplayModeNever : UINavigationItemLargeTitleDisplayModeAlways;
    self.view.tintColor = RBXAccentColor();
    if (self.wizardMode) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:@"Skip" style:UIBarButtonItemStylePlain
            target:self action:@selector(closeWizard)];
    }

    if (![self.appDescriptor[@"runnable"] boolValue]) {
        [self buildSourceSetup];
        return;
    }

    UIScrollView *scroll = [UIScrollView new];
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];

    UIStackView *stack = [[UIStackView alloc] init];
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
    if (!self.proxyMode) {
    self.generalAdvancedFields = RBXVerticalStack(@[],20);
    UIStackView *status = RBXFormSection(page, @"This device", nil);
    UIStackView *server = RBXVerticalStack(@[],4);
    [server addArrangedSubview:[self caption:@"CLOUD SERVER"]];
    self.serverStatusLabel = RBXLabel(@"Checking configuration…",UIFontTextStyleHeadline,NO);
    self.serverDetailLabel = [self caption:@"A saved address does not prove a live connection."];
    [server addArrangedSubview:self.serverStatusLabel];
    [server addArrangedSubview:self.serverDetailLabel];
    UIStackView *license = RBXVerticalStack(@[],4);
    [license addArrangedSubview:[self caption:@"LICENSE"]];
    self.licenseStatusLabel = RBXLabel(@"Checking activation…",UIFontTextStyleHeadline,NO);
    self.licenseDetailLabel = [self caption:@"Waiting for current device status."];
    [license addArrangedSubview:self.licenseStatusLabel];
    [license addArrangedSubview:self.licenseDetailLabel];
    [status addArrangedSubview:server];
    [status addArrangedSubview:license];
    NSString *packageLayout = @"Package layout not reported";
#if defined(RBX_PACKAGE_ROOTLESS)
    packageLayout = RBX_PACKAGE_ROOTLESS ? @"Rootless package" : @"Rootful package";
#endif
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"Unknown";
    [status addArrangedSubview:[self caption:[NSString stringWithFormat:@"iOS %@ · %@ · SocialBox %@",UIDevice.currentDevice.systemVersion,packageLayout,version]]];
    UIButton *account = [UIButton buttonWithType:UIButtonTypeSystem];
    [account setTitle:@"Account & license" forState:UIControlStateNormal];
    RBXStyleButton(account,NO);
    [account addTarget:self action:@selector(openAccount) forControlEvents:UIControlEventTouchUpInside];
    [status addArrangedSubview:account];
    stack = RBXFormSection(page, self.wizardMode ? @"First-time setup" : @"Before you open an app", nil);
    if (self.wizardMode) {
        UILabel *welcome = [self caption:
            [self appText:@"Import a decrypted Reddit IPA, save and test your proxy, then complete managed VPN setup. You can skip and return later. Settings and profile management remain available before VPN setup; Reddit traffic stays closed."]];
        welcome.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [stack addArrangedSubview:welcome];
    }

    self.firewallSetupLabel = [self caption:[self appText:@"VPN is not configured. Reddit traffic stays closed; offline setup remains available."]];
    self.firewallSetupLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [stack addArrangedSubview:self.firewallSetupLabel];
    [stack addArrangedSubview:[self caption:@"Green means this check passed. Red means setup or verification is still needed. Tap a step to continue. Offline container creation remains available."]];
    self.setupRows=RBXVerticalStack(@[],12);
    [stack addArrangedSubview:self.setupRows];

    UIStackView *evidence = RBXFormSection(self.generalAdvancedFields,@"Service & isolation evidence",@"These checks support troubleshooting. Setup flags cannot prove that every app data surface or network route is isolated.");
    self.setupEvidenceRows = RBXVerticalStack(@[],12);
    [evidence addArrangedSubview:self.setupEvidenceRows];
    UIButton *diagnostics = [UIButton buttonWithType:UIButtonTypeSystem];
    [diagnostics setTitle:@"Open isolation diagnostics" forState:UIControlStateNormal];
    RBXStyleButton(diagnostics,NO);
    [diagnostics addTarget:self action:@selector(openDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    [evidence addArrangedSubview:diagnostics];

    UIStackView *cloudCard = RBXFormSection(page,@"Cloud & transfer",@"Back up a container, then restore on another phone using the same license and encryption key. Your web console manages the same encrypted backups.");
    [cloudCard addArrangedSubview:[self caption:@"Includes app files and logical identity. Keychain and hardware-bound credentials do not transfer; some apps may need you to sign in again."]];
    UIButton *cloud = [UIButton buttonWithType:UIButtonTypeSystem];
    [cloud setTitle:@"Open cloud backups" forState:UIControlStateNormal];
    RBXStyleButton(cloud,NO);
    [cloud addTarget:self action:@selector(openCloudVault) forControlEvents:UIControlEventTouchUpInside];
    [cloudCard addArrangedSubview:cloud];
    UIStackView *appearance = RBXFormSection(page, @"Appearance", @"Choose how SocialBox looks on this phone.");
    UISegmentedControl *theme = [[UISegmentedControl alloc] initWithItems:@[@"System", @"Light", @"Dark"]];
    theme.selectedSegmentIndex = RBXPreferredAppearance();
    theme.accessibilityLabel = @"Appearance";
    [theme addTarget:self action:@selector(changeAppearance:) forControlEvents:UIControlEventValueChanged];
    [appearance addArrangedSubview:theme];
    stack = RBXFormSection(self.generalAdvancedFields, @"Defaults & updates", @"Defaults affect new containers only. Existing identities stay unchanged.");
    [stack addArrangedSubview:[self caption:
        @"IDFA behavior is configured in each profile's Identity editor. Clone traffic stays closed until that profile passes the protected launch sequence."]];
    [stack addArrangedSubview:[self caption:@"Default country for new containers · blank = Auto from proxy"]];
    self.defaultCountryField = [self field:@"Auto from proxy" secure:NO];
    self.defaultCountryField.text = RBXCreationDefaults(NSUserDefaults.standardUserDefaults, self.appDescriptor, nil)[@"country"];
    self.defaultCountryField.autocapitalizationType =
        UITextAutocapitalizationTypeAllCharacters;
    [self.defaultCountryField addTarget:self action:@selector(saveGeneralSettings)
                     forControlEvents:UIControlEventEditingDidEnd];
    [stack addArrangedSubview:self.defaultCountryField];
    [stack addArrangedSubview:[self caption:@"Default role for new containers (labels only)"]];
    UISegmentedControl *defaultRole = [[UISegmentedControl alloc] initWithItems:RBXProfileRoles()];
    defaultRole.selectedSegmentIndex = [RBXProfileRoles() indexOfObject:
        RBXProfileRole([NSUserDefaults.standardUserDefaults stringForKey:RBXAppScopedPreferenceKey(@"RBXDefaultRole", self.appDescriptor)])];
    defaultRole.accessibilityLabel = @"Default profile role";
    [defaultRole addTarget:self action:@selector(saveDefaultRole:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:defaultRole];

    if ([self.appDescriptor[@"appType"] isEqual:@"reddit"]) {
    NSDictionary *versionSettings = [NSDictionary dictionaryWithContentsOfFile:
        RBXAppVersionPrefsPath] ?: @{};
    [stack addArrangedSubview:[self caption:[self appText:@"Reddit update monitoring"]]];
    self.latestVersionField = [self field:@"Latest known version (for example 2026.35.0)"
                                   secure:NO];
    self.latestVersionField.text = versionSettings[@"latestKnownVersion"] ?: @"";
    [self.latestVersionField addTarget:self action:@selector(saveAppVersionSettings)
                      forControlEvents:UIControlEventEditingDidEnd];
    [stack addArrangedSubview:self.latestVersionField];
    self.versionIntervalField = [self field:@"Check interval in hours (24)" secure:NO];
    self.versionIntervalField.keyboardType = UIKeyboardTypeNumberPad;
    self.versionIntervalField.text = [versionSettings[@"checkIntervalHours"] stringValue]
        ?: @"24";
    [self.versionIntervalField addTarget:self action:@selector(saveAppVersionSettings)
                        forControlEvents:UIControlEventEditingDidEnd];
    [stack addArrangedSubview:self.versionIntervalField];
    }

    }
    if (self.proxyMode || self.wizardMode) {
    stack = RBXFormSection(page, @"Your proxy", @"Add your HTTP proxy to connect. A rotation link is optional.");
    [stack addArrangedSubview:[self caption:@"Proxy URL"]];
    self.proxyField = [self field:@"http://user:password@host:port" secure:NO];
    self.proxyField.keyboardType = UIKeyboardTypeURL;
    [stack addArrangedSubview:self.proxyField];

    [stack addArrangedSubview:[self caption:@"Rotation link · optional"]];
    self.rotationField = [self field:@"https://provider.example/api/rotate" secure:NO];
    self.rotationField.keyboardType = UIKeyboardTypeURL;
    [stack addArrangedSubview:self.rotationField];

    [stack addArrangedSubview:[self caption:@"Leave blank if your provider does not offer IP rotation."]];
    self.advancedProxyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.advancedProxyButton setTitle:@"Advanced options" forState:UIControlStateNormal];
    [self.advancedProxyButton addTarget:self action:@selector(toggleAdvancedProxy) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.advancedProxyButton];
    UIStackView *proxyCard = stack;
    self.advancedProxyFields = RBXVerticalStack(@[], 12);
    self.advancedProxyFields.hidden = YES;
    [stack addArrangedSubview:self.advancedProxyFields];
    stack = self.advancedProxyFields;
    [stack addArrangedSubview:[self caption:@"Only needed if your provider requires a custom header or POST request."]];
    [stack addArrangedSubview:[self caption:@"Authorization header name"]];
    self.headerField = [self field:@"Authorization" secure:NO];
    [stack addArrangedSubview:self.headerField];

    [stack addArrangedSubview:[self caption:@"Authorization value / token"]];
    self.authorizationField = [self field:@"Bearer …" secure:YES];
    self.authorizationField.textContentType = UITextContentTypePassword;
    [stack addArrangedSubview:self.authorizationField];

    [stack addArrangedSubview:[self caption:@"Rotation method"]];
    self.methodControl = [[UISegmentedControl alloc] initWithItems:@[@"POST", @"GET"]];
    self.methodControl.selectedSegmentIndex = 1;
    [stack addArrangedSubview:self.methodControl];
    stack = proxyCard;

    self.sourceLabel = [self caption:@""];
    [stack addArrangedSubview:self.sourceLabel];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"Save proxy" forState:UIControlStateNormal];
    RBXStyleButton(save, NO);
    [save addTarget:self action:@selector(saveSettings)
   forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:save];

    self.testButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.testButton setTitle:@"Save and test connection" forState:UIControlStateNormal];
    RBXStyleButton(self.testButton, YES);
    [self.testButton addTarget:self action:@selector(testSettings)
              forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.testButton];
    [stack addArrangedSubview:[self caption:
        [self appText:@"Testing pauses any active app session and checks the proxy connection. If supplied, your rotation link is called once first."]]];

    self.testLabel = [self caption:@"Not tested yet"];
    [stack addArrangedSubview:self.testLabel];

    }
    if (!self.proxyMode) {
    stack = RBXFormSection(page, [self appText:@"Reddit source"], nil);
    self.redditSourceLabel = [self caption:@""];
    [stack addArrangedSubview:self.redditSourceLabel];
    [stack addArrangedSubview:[self caption:
        [NSString stringWithFormat:@"Choose your decrypted %@ IPA from Files. SocialBox checks the bundle and encryption before keeping a private source. Your existing containers are kept.", self.appDescriptor[@"displayName"]]]];
    self.sourceImportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sourceImportButton setTitle:[self appText:@"Import Reddit IPA from Files"]
        forState:UIControlStateNormal];
    RBXStyleButton(self.sourceImportButton, NO);
    [self.sourceImportButton addTarget:self action:@selector(importSource)
        forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.sourceImportButton];
    self.sourceImportRequestId = [NSUserDefaults.standardUserDefaults
        stringForKey:RBXAppSourceImportRequestKey(self.sourceImportDescriptor)];

    stack = RBXFormSection(page, @"Network protection", @"This build requires MDM, a device-management service that installs each clone and assigns its protected VPN. A saved proxy alone does not establish this protection.");
    UILabel *networkRequirement = [self caption:@"No MDM? You can prepare containers offline. Online launch stays blocked until protected routing is verified."];
    networkRequirement.textColor = [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
    [stack addArrangedSubview:networkRequirement];
    UIStackView *networkDetails = RBXFormSection(self.generalAdvancedFields,@"Managed VPN setup details",@"1. Confirm MDM enrollment and support for these exact clone IPAs. This iOS VPN payload does not itself require supervision; do not erase your phone just to complete this checklist.\n\n2. Share the setup files and each clone IPA with your MDM administrator. They must install or adopt the clone and assign its per-app VPN.\n\n3. Open Firewall Setup and verify actual routing in Diagnostics. Installing a VPN profile alone does not prove that a clone uses it.");
    [networkDetails addArrangedSubview:[self caption:@"A different source IPA or device model does not replace network protection. Review the evidence again after rebuilding a clone."]];
    UIButton *shareMDM = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareMDM setTitle:@"Share MDM/VPN setup files" forState:UIControlStateNormal];
    RBXStyleButton(shareMDM, NO);
    [shareMDM addTarget:self action:@selector(shareManagedSetup)
        forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:shareMDM];
    UIButton *openFirewall = [UIButton buttonWithType:UIButtonTypeSystem];
    [openFirewall setTitle:@"Open Firewall Setup" forState:UIControlStateNormal];
    RBXStyleButton(openFirewall, YES);
    [openFirewall addTarget:self action:@selector(openFirewallSetup)
        forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:openFirewall];

    stack = RBXFormSection(self.generalAdvancedFields, @"Legacy cloud pairing", @"Normal setup uses Account & license above. Use these fields only for an existing pairing-code setup; an activated device does not need another code.");
    [stack addArrangedSubview:[self caption:@"RedditBox access/license key"]];
    self.accessKeyField = [self field:@"RedditBox access/license key" secure:YES];
    [stack addArrangedSubview:self.accessKeyField];
    [stack addArrangedSubview:[self caption:@"Cloud server URL"]];
    self.cloudServerField = [self field:@"https://your-redditbox-cloud.example" secure:NO];
    self.cloudServerField.keyboardType = UIKeyboardTypeURL;
    [stack addArrangedSubview:self.cloudServerField];
    [stack addArrangedSubview:[self caption:@"Pairing code"]];
    self.pairingCodeField = [self field:@"Pairing code from cloud console" secure:NO];
    self.pairingCodeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    [stack addArrangedSubview:self.pairingCodeField];
    UIButton *pair = [UIButton buttonWithType:UIButtonTypeSystem];
    [pair setTitle:@"Pair and sync cloud settings" forState:UIControlStateNormal];
    RBXStyleButton(pair, NO);
    [pair addTarget:self action:@selector(pairCloud)
   forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:pair];
    self.cloudStatusLabel = [self caption:@"Activate a device license first. An activated device does not need another pairing code."];
    [stack addArrangedSubview:self.cloudStatusLabel];

    }
    if (self.generalAdvancedFields) {
        UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
        [more setTitle:@"Advanced & evidence" forState:UIControlStateNormal];
        more.accessibilityIdentifier = @"settings.advanced";
        RBXStyleButton(more, NO);
        [more addTarget:self action:@selector(toggleGeneralAdvanced:) forControlEvents:UIControlEventTouchUpInside];
        [page addArrangedSubview:more];
        self.generalAdvancedFields.hidden = YES;
        [page addArrangedSubview:self.generalAdvancedFields];
    }
    [self loadConfiguration];
    [self refreshStatus];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, RBXSettingsStateChanged,
        CFSTR("com.redditbox.launcherStateChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

// Inactive support exposes only safe source staging. Global settings stay in
// the existing device workspace until this app has an executable lifecycle.
- (void)buildSourceSetup {
    self.navigationItem.title = [NSString stringWithFormat:@"%@ source", self.appDescriptor[@"displayName"]];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *page = RBXVerticalStack(@[], 20);
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [page.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [page.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [page.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [page.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [page.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
    [page addArrangedSubview:[self caption:@"Source import is available. Container creation, opening and MDM export remain pending verification for this app."]];
    self.redditSourceLabel = [self caption:@"Checking source…"];
    [page addArrangedSubview:self.redditSourceLabel];
    [page addArrangedSubview:[self caption:[NSString stringWithFormat:@"Choose a decrypted %@ IPA. The daemon validates its bundle, Mach-O files and encryption before publishing this app's private source. Import closes any active session on the device.", self.appDescriptor[@"displayName"]]]];
    self.sourceImportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sourceImportButton setTitle:[NSString stringWithFormat:@"Import %@ IPA from Files", self.appDescriptor[@"displayName"]] forState:UIControlStateNormal];
    RBXStyleButton(self.sourceImportButton, YES);
    [self.sourceImportButton addTarget:self action:@selector(importSource) forControlEvents:UIControlEventTouchUpInside];
    [page addArrangedSubview:self.sourceImportButton];
    [page addArrangedSubview:[self caption:@"Proxy, license and network protection remain device-wide. Close this sheet to manage them in the existing workspace."]];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, RBXSettingsStateChanged,
        CFSTR("com.redditbox.launcherStateChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, NULL, NULL);
}

- (void)loadConfiguration {
    NSError *error = nil;
    NSDictionary *config = [RBXSecureConfig rotationConfiguration:&error];
    self.proxyField.text = config[@"proxyURL"] ?: @"";
    self.rotationField.text = config[@"rotationURL"] ?: @"";
    self.headerField.text = config[@"authHeader"] ?: @"Authorization";
    self.authorizationField.text = config[@"authorization"] ?: @"";
    self.accessKeyField.text = config[@"accessKey"] ?: @"";
    self.methodControl.selectedSegmentIndex =
        [(config[@"method"] ?: @"GET") isEqualToString:@"GET"] ? 1 : 0;
    self.sourceLabel.text = error.localizedDescription ?: [NSString stringWithFormat:
        @"Current source: %@", config[@"source"] ?: (config ? @"launcher" : @"not configured")];
    self.loadedConfigurationAt = [config[@"updatedAt"] doubleValue];
}

- (BOOL)validateAndSave {
    NSString *proxyText = [RBXProxyLibrary normalizedURL:self.proxyField.text];
    NSString *rotationText = [self.rotationField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *header = [self.headerField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *authorization = [self.authorizationField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *rotation = [NSURL URLWithString:rotationText];
    BOOL proxyValid = RBXParseHTTPProxyURL(proxyText) != nil;
    BOOL rotationValid = !rotationText.length || ([rotation.scheme.lowercaseString isEqualToString:@"https"] &&
        rotation.host.length && !rotation.user.length && !rotation.password.length && !rotation.fragment.length);
    NSCharacterSet *invalidHeader = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"]
        invertedSet];
    BOOL headerValid = header.length && header.length <= 128 &&
        [header rangeOfCharacterFromSet:invalidHeader].location == NSNotFound;
    if (!proxyValid || !rotationValid || !headerValid || authorization.length > 4096) {
        [self showMessage:@"Invalid settings"
            detail:@"Enter an HTTP proxy including its port, for example http://user:password@host:8000. Leave rotation blank, or use an HTTPS link. Custom header settings are under Advanced options."];
        return NO;
    }
    NSError *error = nil;
    BOOL saved = [RBXSecureConfig saveRotationConfiguration:@{
        @"proxyURL": proxyText,
        @"rotationURL": rotationText,
        @"authHeader": header,
        @"authorization": authorization,
        @"method": self.methodControl.selectedSegmentIndex == 1 ? @"GET" : @"POST",
        @"source": @"launcher",
    } error:&error];
    if (saved && self.accessKeyField) {
        saved = [RBXSecureConfig saveAccessKey:self.accessKeyField.text ?: @""
                                        error:&error];
    }
    if (!saved) {
        [self showMessage:@"Could not save" detail:error.localizedDescription];
        return NO;
    }
    self.proxyField.text = proxyText;
    self.sourceLabel.text = @"Current source: launcher Keychain";
    return YES;
}

- (void)saveSettings {
    if (![self validateAndSave]) return;
    if ([self submitAction:@"configurationChanged" values:@{}]) {
        self.sourceLabel.text = @"Saved securely. Waiting for the daemon to apply the settings…";
    }
}

- (void)testSettings {
    if ([self hasPendingAction:@"testConfiguration"]) return;
    if (![self validateAndSave]) return;
    self.testButton.enabled = NO;
    self.testResult = nil;
    self.testLabel.textColor = UIColor.secondaryLabelColor;
    self.testLabel.text = @"Testing proxy connection…";
    if (![self submitAction:@"testConfiguration" values:@{}]) {
        self.testButton.enabled = YES;
        self.testLabel.textColor = UIColor.systemRedColor;
        self.testLabel.text = @"The connection test request could not be sent.";
    }
}

- (void)requestsDidBecomeActive:(NSNotification *)notification {
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // A tab can load before it inherits the window's chosen appearance.
    [self refreshWorkspaceBackground];
    [self refreshStatus];
    [self.setupTimer invalidate];
    __weak typeof(self) weakSelf=self;
    self.setupTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) { [weakSelf refreshStatus]; }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.setupTimer invalidate]; self.setupTimer=nil;
}

- (BOOL)hasPendingAction:(NSString *)action {
    for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
        if ([request[@"action"] isEqualToString:action]) return YES;
    }
    return NO;
}

- (NSString *)submitAction:(NSString *)action values:(NSDictionary *)values {
    NSString *requestId = [RBXLauncherIPC sendActionReturningRequestId:action values:values
        notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
    if (!requestId.length) {
        [self showMessage:@"Request failed"
            detail:@"The request could not be sent to the daemon. Try again."];
    }
    return requestId;
}

- (void)importSource {
    [self importSourceForAppType:self.appDescriptor[@"appType"]];
}

- (void)importSourceForAppType:(NSString *)appType {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor || ![descriptor[@"appType"] isEqual:self.appDescriptor[@"appType"]]) {
        [self showMessage:@"Source not imported" detail:@"This app type is not registered. Choose a supported app workspace."];
        return;
    }
    if (self.stagingSourceImport || self.presentedViewController) return;
    self.sourceImportDescriptor = descriptor;
    self.sourceImportRequestId = [NSUserDefaults.standardUserDefaults
        stringForKey:RBXAppSourceImportRequestKey(descriptor)];
    if ([descriptor[@"appType"] isEqual:RBXRedditAppDescriptor()[@"appType"]])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RBXLegacySourceImportNotice"];
    self.sourceImportLocalError = nil;
    // Import mode obtains a coordinated local copy from Files, including cloud
    // document providers. Validate the filename and archive again before use.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"com.apple.itunes.ipa", @"public.zip-archive", @"public.data"]
        inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSDictionary *descriptor = self.sourceImportDescriptor;
    if (!RBXAppDescriptorIsRegistered(descriptor)) return;
    NSURL *url = urls.count == 1 ? urls.firstObject : nil;
    if (!url.isFileURL || ![url.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
        self.sourceImportLocalError = @"Choose one file ending in .ipa.";
        [self refreshStatus];
        return;
    }
    self.stagingSourceImport = YES;
    self.sourceImportButton.enabled = NO;
    [self refreshStatus];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        __block NSString *stagedPath = nil;
        __block NSError *copyError = nil;
        NSError *coordinationError = nil;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError
            byAccessor:^(NSURL *readURL) {
                stagedPath = RBXStageSourceIPA(readURL, descriptor, &copyError);
            }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        NSError *error = coordinationError ?: copyError;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.stagingSourceImport = NO;
            if (!stagedPath || error) {
                if (stagedPath) [NSFileManager.defaultManager removeItemAtPath:stagedPath error:nil];
                self.sourceImportLocalError = error.localizedDescription ?: @"The IPA could not be copied from Files.";
                [self refreshStatus];
                return;
            }
            NSString *requestId = [RBXLauncherIPC sendActionReturningRequestId:@"import-source"
                values:@{@"ipaPath": stagedPath, @"appType":descriptor[@"appType"]}
                notification:CFSTR("com.redditbox.launcherAction") owner:self.requestOwner appType:self.appDescriptor[@"appType"]];
            if (!requestId.length) {
                [NSFileManager.defaultManager removeItemAtPath:stagedPath error:nil];
                self.sourceImportLocalError = @"The source request could not be sent to the daemon. Try again.";
            } else {
                self.sourceImportRequestId = requestId;
                self.sourceImportLocalError = nil;
                [NSUserDefaults.standardUserDefaults setObject:requestId forKey:RBXAppSourceImportRequestKey(descriptor)];
            }
            [self refreshStatus];
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self refreshStatus];
}

- (void)openFirewallSetup {
    [self submitAction:@"openFirewall" values:@{}];
}

- (void)shareManagedSetup {
    NSDictionary *state = RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:RBXLauncherStatePath], self.appDescriptor) ?: @{};
    NSArray *containers = [state[@"containers"] isKindOfClass:NSArray.class]
        ? state[@"containers"] : @[];
    NSError *error = nil;
    NSArray<NSURL *> *files = [RBXMDMExporter exportFilesForContainers:containers appType:self.appDescriptor[@"appType"] error:&error];
    if (!files.count) {
        [self showMessage:@"MDM export failed"
            detail:error.localizedDescription ?: @"No setup files were created."];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:files applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(
        CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)performSetupAction:(NSString *)action {
    if ([action isEqual:@"source"]) [self importSource];
    else if ([action isEqual:@"firewall"]) [self openFirewallSetup];
    else if ([action isEqual:@"mdm"]) [self shareManagedSetup];
    else if ([action isEqual:@"license"]) {
        RBXLicenseViewController *license=[[RBXLicenseViewController alloc] initWithLicenseState:nil appType:self.appDescriptor[@"appType"]];
        license.navigationItem.hidesBackButton=NO;
        [self.navigationController pushViewController:license animated:YES];
    }
    else if ([action isEqual:@"proxies"]) {
        if (!RBXSelectWorkspaceTab(self, RBXWorkspaceTabProxies)) [self.navigationController pushViewController:[[RBXProxiesViewController alloc] initWithAppType:self.appDescriptor[@"appType"]] animated:YES];
    } else [self openDiagnostics];
}

- (void)renderSetupChecklist:(NSDictionary *)state {
    if (!self.setupRows) return;
    NSArray *rows = RBXSetupChecklist(state,NSDate.date.timeIntervalSince1970);
    if ([rows isEqual:self.renderedSetupRows]) return;
    self.renderedSetupRows = rows;
    for (UIStackView *group in @[self.setupRows,self.setupEvidenceRows]) {
        for (UIView *view in group.arrangedSubviews) {
            [group removeArrangedSubview:view]; [view removeFromSuperview];
        }
    }
    NSSet *primary = [NSSet setWithArray:@[@"license",@"source",@"proxy",@"proxy-test",@"vpn",@"mdm-clones"]];
    NSUInteger passed = 0;
    for (NSDictionary *row in rows) {
        BOOL ok = [row[@"status"] isEqual:@"PASS"]; if (ok) passed++;
        UIStackView *step = RBXVerticalStack(@[],4);
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *title = [self appText:row[@"title"]];
        [button setTitle:[NSString stringWithFormat:@"%@ %@",ok ? @"✓" : @"✕",title] forState:UIControlStateNormal];
        button.tintColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        button.titleLabel.adjustsFontForContentSizeCategory = YES;
        button.titleLabel.numberOfLines = 0;
        button.accessibilityLabel = [NSString stringWithFormat:@"%@. %@",title,ok ? @"Verified" : @"Needs setup or verification"];
        button.accessibilityIdentifier = [@"settings.check." stringByAppendingString:row[@"id"]];
        button.accessibilityHint = [self appText:row[@"detail"]];
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        __weak typeof(self) weakSelf = self;
        [button addAction:[UIAction actionWithHandler:^(UIAction *event) {
            [weakSelf performSetupAction:row[@"action"]];
        }] forControlEvents:UIControlEventTouchUpInside];
        [step addArrangedSubview:button];
        BOOL primaryStep = [primary containsObject:row[@"id"]];
        if (!ok || !primaryStep) [step addArrangedSubview:[self caption:[self appText:row[@"detail"]]]];
        UIStackView *group = primaryStep ? self.setupRows : self.setupEvidenceRows;
        [group addArrangedSubview:step];
    }
    self.firewallSetupLabel.text = [NSString stringWithFormat:@"%lu of %lu checks verified. Service and isolation evidence are under Advanced.",(unsigned long)passed,(unsigned long)rows.count];
    self.firewallSetupLabel.textColor = passed == rows.count ? UIColor.systemGreenColor : UIColor.systemRedColor;
}

- (void)renderDeviceStatus:(NSDictionary *)state {
    NSDictionary *status = RBXSettingsStatusPresentation(state,NSDate.date.timeIntervalSince1970);
    self.serverStatusLabel.text = status[@"serverTitle"];
    self.serverStatusLabel.textColor = [status[@"serverConfigured"] boolValue] ? UIColor.labelColor : UIColor.systemRedColor;
    NSTimeInterval synced = [status[@"cloudReceiptAt"] doubleValue];
    if (synced > 0) {
        NSString *time = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:synced]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
        self.serverDetailLabel.text = [NSString stringWithFormat:@"Last sync %@ · %@\nThis is a saved result, not a live connection check.",[status[@"cloudReceiptOK"] boolValue] ? @"succeeded" : @"failed",time];
    } else {
        self.serverDetailLabel.text = [status[@"serverConfigured"] boolValue]
            ? @"Server address saved. No matching cloud sync result is available."
            : @"Open Account & license to set your cloud server and activate this phone.";
    }
    self.licenseStatusLabel.text = status[@"licenseTitle"];
    self.licenseStatusLabel.textColor = [status[@"licenseActive"] boolValue] ? UIColor.systemGreenColor : UIColor.systemRedColor;
    self.licenseDetailLabel.text = status[@"licenseDetail"];
}

- (void)refreshWorkspaceBackground {
    [self.workspaceBackground removeFromSuperview];
    self.workspaceBackground = RBXWorkspaceBackgroundView(self.view.traitCollection);
    self.workspaceBackground.frame = self.view.bounds;
    self.workspaceBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.workspaceBackground atIndex:0];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.isViewLoaded && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        [self refreshWorkspaceBackground];
}

- (void)refreshStatus {
    if (!self.view.window) return; // Observe this tab's receipts when it is visible.
    NSMutableDictionary *state = [RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:RBXLauncherStatePath], self.appDescriptor) mutableCopy] ?: [NSMutableDictionary dictionary];
    state[@"configuration"]=[RBXSecureConfig safeSummary]; // Invalidate old green immediately after a local edit.
    NSDictionary *feedback = nil;
    BOOL canPresent = self.view.window && !self.presentedViewController &&
        self.navigationController.topViewController == self;
    if (canPresent) {
        for (NSDictionary *request in [RBXLauncherIPC pendingRequestsForOwner:self.requestOwner]) {
            NSString *requestId = request[@"requestId"];
            NSDictionary *result = [RBXLauncherIPC requestResultForId:requestId];
            if (!result) continue;
            [RBXLauncherIPC finishObservingRequestId:requestId owner:self.requestOwner];
            NSString *action = result[@"action"];
            if ([action isEqualToString:@"testConfiguration"]) self.testResult = result;
            else if ([action isEqualToString:@"configureCloud"]) self.cloudResult = result;
            else if (![action isEqualToString:@"import-source"]) {
                feedback = result;
                break;
            }
        }
    }
    [self renderSetupChecklist:state];
    [self renderDeviceStatus:state];
    NSDictionary *configuration = state[@"configuration"];
    if ([configuration[@"updatedAt"] doubleValue] > self.loadedConfigurationAt) {
        [self loadConfiguration];
    }
    NSDictionary *test = RBXLatestProxyTest(state[@"configurationTest"],self.testResult);
    BOOL testPending = [self hasPendingAction:@"testConfiguration"];
    self.testButton.enabled = !testPending;
    if (testPending) {
        self.testLabel.textColor = UIColor.secondaryLabelColor;
        self.testLabel.text = @"Connection test queued or running…";
    } else if (RBXProxyTestCurrent(state,test,NSDate.date.timeIntervalSince1970) && [test[@"ok"] isKindOfClass:NSNumber.class]) {
        BOOL ok = [test[@"ok"] boolValue];
        self.testLabel.textColor = ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
        self.testLabel.text = [NSString stringWithFormat:@"%@ %@",
            ok ? @"✓" : @"✕", test[@"message"] ?: @"Test finished"];
        self.testButton.enabled = YES;
    } else {
        self.testLabel.textColor=UIColor.systemRedColor;
        self.testLabel.text=@"Not verified for the current proxy. Test again after changes or when the previous test expires.";
    }
    NSDictionary *sourceState = [self.sourceImportDescriptor[@"appType"] isEqual:RBXRedditAppDescriptor()[@"appType"]]
        ? state : RBXAppScopedLauncherState([NSDictionary dictionaryWithContentsOfFile:RBXLauncherStatePath], self.sourceImportDescriptor);
    NSDictionary *source = sourceState[@"source"];
    BOOL decrypted = [source[@"decrypted"] isKindOfClass:NSNumber.class] && [source[@"decrypted"] boolValue];
    NSDictionary *sourcePresentation = RBXAppSetupStatus([NSDictionary dictionaryWithContentsOfFile:RBXLauncherStatePath], self.sourceImportDescriptor);
    [self.sourceImportButton setTitle:sourcePresentation[@"importAction"] forState:UIControlStateNormal];
    self.redditSourceLabel.textColor =
        decrypted ? UIColor.systemGreenColor : UIColor.systemRedColor;
    self.redditSourceLabel.text = [NSString stringWithFormat:@"%@ %@%@",
        decrypted ? @"✓" : @"✕",
        source[@"message"] ?: @"Checking source…",
        [source[@"version"] length]
            ? [NSString stringWithFormat:@" (v%@)", source[@"version"]] : @""];
    NSDictionary *sourceImport = self.sourceImportRequestId.length
        ? [RBXLauncherIPC requestResultForId:self.sourceImportRequestId] : nil;
    BOOL importFinished = self.sourceImportRequestId.length &&
        [sourceImport[@"requestId"] isEqualToString:self.sourceImportRequestId] &&
        [sourceImport[@"ok"] isKindOfClass:NSNumber.class];
    self.sourceImportButton.enabled = !self.stagingSourceImport &&
        (!self.sourceImportRequestId.length || importFinished || self.sourceImportLocalError.length);
    NSString *importMessage = nil;
    NSDictionary *legacyNotice = [self.sourceImportDescriptor[@"appType"] isEqual:RBXRedditAppDescriptor()[@"appType"]]
        ? [RBXLauncherIPC legacySourceImportNotice] : nil;
    if (self.stagingSourceImport) importMessage = @"Copying IPA into private storage…";
    else if (self.sourceImportLocalError.length) {
        importMessage = self.sourceImportLocalError;
        self.redditSourceLabel.textColor = UIColor.systemRedColor;
    } else if (importFinished) {
        importMessage = sourceImport[@"message"] ?: @"Source import finished.";
        self.redditSourceLabel.textColor = [sourceImport[@"ok"] boolValue]
            ? UIColor.systemGreenColor : UIColor.systemRedColor;
    } else if (self.sourceImportRequestId.length) {
        importMessage = @"Waiting for the daemon to validate and import this IPA…";
        self.redditSourceLabel.textColor = UIColor.secondaryLabelColor;
    } else if (legacyNotice.count) {
        importMessage = legacyNotice[@"message"];
        self.redditSourceLabel.textColor = [legacyNotice[@"ok"] boolValue]
            ? UIColor.systemGreenColor : [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1];
    }
    if (importMessage.length) self.redditSourceLabel.text = [NSString stringWithFormat:
        @"%@\n%@", self.redditSourceLabel.text, importMessage];
    NSDictionary *cloud = self.cloudResult ?: state[@"cloud"];
    if ([self hasPendingAction:@"configureCloud"]) {
        self.cloudStatusLabel.textColor = UIColor.secondaryLabelColor;
        self.cloudStatusLabel.text = @"Cloud pairing queued or running…";
    } else if ([cloud[@"ok"] isKindOfClass:NSNumber.class]) {
        BOOL ok = [cloud[@"ok"] boolValue];
        self.cloudStatusLabel.textColor =
            ok ? UIColor.systemGreenColor : UIColor.systemRedColor;
        self.cloudStatusLabel.text = [NSString stringWithFormat:@"%@ %@",
            ok ? @"✓" : @"✕", cloud[@"message"] ?: @"Cloud status updated"];
    }
    if (feedback) {
        if (self.wizardMode && [feedback[@"ok"] boolValue] &&
            [feedback[@"action"] isEqualToString:@"configurationChanged"] &&
            ![RBXLauncherIPC pendingRequestsForOwner:self.requestOwner].count) {
            [self closeWizard];
        } else {
            [self showMessage:[feedback[@"ok"] boolValue] ? @"Request completed" : @"Request failed"
                detail:feedback[@"message"] ?: @"The daemon completed this request."];
        }
    }
}

- (void)pairCloud {
    if ([self hasPendingAction:@"configureCloud"]) return;
    NSString *server = [self.cloudServerField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *code = [[self.pairingCodeField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        uppercaseString];
    NSURL *url = [NSURL URLWithString:server];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        !url.host.length || !code.length) {
        [self showMessage:@"Cloud settings incomplete"
            detail:@"Enter an HTTPS server URL and the pairing code from the cloud console."];
        return;
    }
    NSError *keyError = nil;
    if (![RBXSecureConfig saveAccessKey:self.accessKeyField.text ?: @""
                                   error:&keyError]) {
        [self showMessage:@"Access key not saved" detail:keyError.localizedDescription];
        return;
    }
    self.cloudStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.cloudStatusLabel.text = @"Pairing…";
    self.cloudResult = nil;
    if (![self submitAction:@"configureCloud" values:@{
        @"serverURL": server, @"pairingCode": code}]) {
        self.cloudStatusLabel.textColor = UIColor.systemRedColor;
        self.cloudStatusLabel.text = @"The pairing request could not be sent.";
    }
}

- (void)saveDefaultRole:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex >= 0 && sender.selectedSegmentIndex < (NSInteger)RBXProfileRoles().count)
        [NSUserDefaults.standardUserDefaults setObject:RBXProfileRoles()[sender.selectedSegmentIndex] forKey:RBXAppScopedPreferenceKey(@"RBXDefaultRole", self.appDescriptor)];
}

- (void)saveGeneralSettings {
    NSString *country = [[self.defaultCountryField.text ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        uppercaseString];
    if (country.length && [RBXOperatorCountry(country) isEqual:@"Country not verified"]) {
        [self showMessage:@"Invalid default country"
            detail:@"Leave blank for Auto from proxy, or enter a two-letter country code."];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:country forKey:RBXAppScopedPreferenceKey(@"RBXDefaultCountry", self.appDescriptor)];
    self.defaultCountryField.text = country;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.redditbox.prefsChanged"), NULL, NULL, TRUE);
}

- (void)saveAppVersionSettings {
    if (![self.appDescriptor[@"appType"] isEqual:@"reddit"]) return;
    NSString *version = [self.latestVersionField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *interval = [self.versionIntervalField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger hours = interval.integerValue;
    if (version.length && [version rangeOfString:
        @"^[0-9]+(\\.[0-9]+){1,3}$" options:NSRegularExpressionSearch].location ==
        NSNotFound) {
        [self showMessage:@"Invalid version"
            detail:[self appText:@"Use a numeric Reddit version such as 2026.35.0."]];
        return;
    }
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    if (!interval.length || [interval rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound ||
        hours < 1 || hours > 720) {
        [self showMessage:@"Invalid check interval"
            detail:@"Enter a whole number of hours from 1 to 720, then try again."];
        return;
    }
    NSMutableDictionary *settings = [NSMutableDictionary
        dictionaryWithContentsOfFile:RBXAppVersionPrefsPath]
        ?: [NSMutableDictionary dictionary];
    if (version.length) settings[@"latestKnownVersion"] = version;
    else [settings removeObjectForKey:@"latestKnownVersion"];
    settings[@"checkIntervalHours"] = @(hours);
    if (![settings writeToFile:RBXAppVersionPrefsPath atomically:YES]) {
        [self showMessage:@"Could not save settings"
            detail:@"The update-monitor settings could not be written. Check available storage, then try again."];
        return;
    }
    self.versionIntervalField.text = [NSString stringWithFormat:@"%ld", (long)hours];
    [self submitAction:@"appVersionConfigurationChanged" values:@{}];
}

- (void)closeWizard {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showMessage:(NSString *)title detail:(NSString *)detail {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:RBXOperatorMessage(detail) preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self dismissViewControllerAnimated:YES completion:^{ [self refreshStatus]; }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
