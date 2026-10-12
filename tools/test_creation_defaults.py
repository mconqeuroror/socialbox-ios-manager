#!/usr/bin/env python3
"""Execute shipped creation code with inert UI/IPC doubles and private preferences.

The full createContainer method and wizard field initialization are extracted
unchanged except that the standard-defaults receiver is a temporary test suite.
No daemon requests, account operations, simulator state, or user preferences.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
launcher = (ROOT / "launcher/RBXLauncherViewController.m").read_text()
method = launcher[launcher.index("- (void)createContainer {"):launcher.index("- (void)groupingChanged")]
wizard = (ROOT / "launcher/RBXSimpleWizardViewController.m").read_text()
settings = (ROOT / "launcher/RBXSettingsViewController.m").read_text()
settings_method = settings[settings.index("- (void)saveGeneralSettings {"):settings.index("- (void)saveAppVersionSettings {")]
settings_load_start = settings.index("self.defaultCountryField.text =")
settings_load = settings[settings_load_start:settings.index(";", settings_load_start) + 1]
initializers = []
for line in wizard.splitlines():
    if "NSDictionary *creationDefaults =" in line or "self.roleControl = [[UISegmentedControl" in line or "NSUInteger role =" in line or "self.roleControl.selectedSegmentIndex =" in line or "self.countryField = [self field:" in line:
        initializers.append(line)
assert len(initializers) in (4, 5), "Wizard fixture must execute each production field initializer"
code = r'''
#import <Foundation/Foundation.h>
#import "RBXAppScope.h"
#import "RBXProfileMetadata.h"
#import "RBXOperatorWording.h"
#if __has_include("RBXCreationDefaults.h")
#import "RBXCreationDefaults.h"
#endif
static NSUserDefaults *fixtureDefaults;
static void FixturePostNotification(CFNotificationCenterRef center, CFStringRef name,
    const void *object, CFDictionaryRef info, Boolean deliver) { }
enum { UIAlertControllerStyleAlert, UIAlertActionStyleCancel, UIAlertActionStyleDefault,
       UITextAutocapitalizationTypeWords, UITextAutocapitalizationTypeAllCharacters,
       UITextAutocapitalizationTypeNone, UITextAutocorrectionTypeNo };
@interface UITextField : NSObject
@property NSString *text, *placeholder;
@property NSInteger autocapitalizationType, autocorrectionType;
@end
@implementation UITextField
@end
@interface UISegmentedControl : NSObject
@property NSInteger selectedSegmentIndex;
- (instancetype)initWithItems:(NSArray *)items;
@end
@implementation UISegmentedControl
- (instancetype)initWithItems:(NSArray *)items { return [super init]; }
@end
@interface UIAlertAction : NSObject
@property(copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self new]; action.handler = handler; return action;
}
@end
@interface UIAlertController : NSObject
@property NSMutableArray<UITextField *> *textFields;
@property NSMutableArray<UIAlertAction *> *actions;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addTextFieldWithConfigurationHandler:(void (^)(UITextField *))handler;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style {
    UIAlertController *form = [self new]; form.textFields = [NSMutableArray array]; form.actions = [NSMutableArray array]; return form;
}
- (void)addTextFieldWithConfigurationHandler:(void (^)(UITextField *))handler { UITextField *field = [UITextField new]; handler(field); [self.textFields addObject:field]; }
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end
@interface RBXSimpleWizardViewController : NSObject
@property NSString *appType;
- (instancetype)initWithAppType:(NSString *)appType;
@end
@implementation RBXSimpleWizardViewController
- (instancetype)initWithAppType:(NSString *)appType { if ((self = [super init])) self.appType = appType; return self; }
@end
@interface FixtureNavigation : NSObject
@property id pushed;
- (void)pushViewController:(id)controller animated:(BOOL)animated;
@end
@implementation FixtureNavigation
- (void)pushViewController:(id)controller animated:(BOOL)animated { self.pushed = controller; }
@end
@interface FixtureLauncher : NSObject
@property BOOL unlocked, licensed, advancedMode;
@property NSDictionary *appDescriptor, *launcherState, *capturedValues;
@property NSString *capturedAction, *errorMessage;
@property FixtureNavigation *navigationController;
@property UIAlertController *presented;
- (void)createContainer;
- (NSString *)appText:(NSString *)text;
- (void)showMessage:(NSString *)title detail:(NSString *)detail;
- (void)requestAction:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)notification;
- (void)presentViewController:(id)controller animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@implementation FixtureLauncher
- (NSString *)appText:(NSString *)text { return text; }
- (void)showMessage:(NSString *)title detail:(NSString *)detail { self.errorMessage = detail; }
- (void)requestAction:(NSString *)action values:(NSDictionary *)values notification:(CFStringRef)notification { self.capturedAction = action; self.capturedValues = values; }
- (void)presentViewController:(id)controller animated:(BOOL)animated completion:(void (^)(void))completion { self.presented = controller; }
''' + method + r'''
@end
@interface FixtureWizard : NSObject
@property NSDictionary *draft, *appDescriptor;
@property UISegmentedControl *roleControl;
@property UITextField *countryField;
- (void)initializeFields;
- (UITextField *)field:(NSString *)placeholder text:(NSString *)text;
@end
@implementation FixtureWizard
- (UITextField *)field:(NSString *)placeholder text:(NSString *)text { UITextField *field = [UITextField new]; field.text = text; return field; }
- (void)initializeFields {
''' + "\n".join(initializers) + r'''
}
@end
@interface FixtureSettings : NSObject
@property NSDictionary *appDescriptor;
@property UITextField *defaultCountryField;
@property NSString *errorMessage;
- (void)initializeCountry;
- (void)saveGeneralSettings;
- (void)showMessage:(NSString *)title detail:(NSString *)detail;
@end
@implementation FixtureSettings
- (void)showMessage:(NSString *)title detail:(NSString *)detail { self.errorMessage = detail; }
- (void)initializeCountry {
''' + settings_load + r'''
}
''' + settings_method.replace("CFNotificationCenterPostNotification", "FixturePostNotification") + r'''
@end
static NSUInteger Checks;
static void Check(BOOL result, NSString *message) {
    Checks++;
    if (!result) [NSException raise:@"CreationDefaultsAssertion" format:@"%@", message];
}
static void Submit(FixtureLauncher *launcher) { UIAlertAction *create = launcher.presented.actions.lastObject; create.handler(create); }
int main(void) { @autoreleasepool {
    NSString *suite = [@"com.redditbox.creation-defaults-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    fixtureDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    @try {
        NSDictionary *reddit = RBXAppDescriptorForType(@"reddit"), *facebook = RBXAppDescriptorForType(@"facebook");
        FixtureSettings *settings = [FixtureSettings new]; settings.appDescriptor = reddit; settings.defaultCountryField = [UITextField new];
        [settings initializeCountry];
        Check([settings.defaultCountryField.text isEqual:@""], @"absent default country must display Auto, not a phantom US default");
        settings.defaultCountryField.text = @"   "; [settings saveGeneralSettings];
        Check([[fixtureDefaults objectForKey:@"RBXDefaultCountry"] isEqual:@""], @"clearing default country must persist Auto, never silently US");
        settings.defaultCountryField.text = @" sk "; [settings saveGeneralSettings];
        Check([[fixtureDefaults objectForKey:@"RBXDefaultCountry"] isEqual:@"SK"] && [settings.defaultCountryField.text isEqual:@"SK"], @"saved country and visible text must agree");
        settings.defaultCountryField.text = @"1?"; [settings saveGeneralSettings];
        Check(settings.errorMessage.length && [[fixtureDefaults objectForKey:@"RBXDefaultCountry"] isEqual:@"SK"], @"malformed country is rejected without changing the saved setting");
        [fixtureDefaults setObject:@" sk " forKey:RBXAppScopedPreferenceKey(@"RBXDefaultCountry", reddit)];
        [fixtureDefaults setObject:@"warmup" forKey:RBXAppScopedPreferenceKey(@"RBXDefaultRole", reddit)];
        [fixtureDefaults setObject:@"DE" forKey:RBXAppScopedPreferenceKey(@"RBXDefaultCountry", facebook)];
        [fixtureDefaults setObject:@"signup" forKey:RBXAppScopedPreferenceKey(@"RBXDefaultRole", facebook)];
        FixtureLauncher *launcher = [FixtureLauncher new]; launcher.unlocked = YES; launcher.licensed = YES;
        launcher.appDescriptor = reddit; launcher.launcherState = @{};
        launcher.navigationController = [FixtureNavigation new];
        [launcher createContainer];
        Check([launcher.navigationController.pushed isKindOfClass:RBXSimpleWizardViewController.class] &&
            [((RBXSimpleWizardViewController *)launcher.navigationController.pushed).appType isEqual:@"reddit"],
            @"normal Reddit create routes to the prepare/review wizard with exact Reddit scope");
        Check(!launcher.presented && !launcher.capturedAction && !launcher.capturedValues,
            @"entering normal creation never presents the old materializing alert or sends creation IPC");
        launcher.advancedMode = YES; [launcher createContainer];
        Check([launcher.presented.textFields[1].text isEqual:@"SK"], @"advanced legacy create must display the saved country");
        Submit(launcher);
        Check([launcher.capturedValues[@"country"] isEqual:@"SK"] && [launcher.capturedValues[@"role"] isEqual:@"warmup"], @"advanced legacy create must submit both scoped defaults");
        launcher.presented.textFields[1].text = @""; Submit(launcher);
        Check([launcher.capturedValues[@"autoRegion"] isEqual:@YES] && [launcher.capturedValues[@"country"] isEqual:@""], @"explicit clearing selects Auto and is not overwritten on submit");
        [launcher createContainer];
        Check([launcher.presented.textFields[2].text isEqual:@"warmup"], @"advanced role starts from the same saved default");
        launcher.presented.textFields[2].text = @"signup"; launcher.presented.textFields[1].text = @"de"; Submit(launcher);
        Check([launcher.capturedValues[@"role"] isEqual:@"signup"] && [launcher.capturedValues[@"country"] isEqual:@"DE"], @"explicit advanced edits override defaults");
        FixtureWizard *wizard = [FixtureWizard new]; wizard.appDescriptor = reddit; wizard.draft = @{}; [wizard initializeFields];
        Check([wizard.countryField.text isEqual:@"SK"] && wizard.roleControl.selectedSegmentIndex == 2, @"wizard uses the same app-scoped country and role");
        wizard.appDescriptor = facebook; [wizard initializeFields];
        Check([wizard.countryField.text isEqual:@"DE"] && wizard.roleControl.selectedSegmentIndex == 1, @"Facebook draft defaults never consume Reddit preferences");
        wizard.draft = @{@"country":@"",@"role":@"spam"}; [wizard initializeFields];
        Check([wizard.countryField.text isEqual:@""] && wizard.roleControl.selectedSegmentIndex == 3, @"saved draft and explicit Auto win over current defaults");
        [fixtureDefaults removePersistentDomainForName:suite]; wizard.draft = @{}; wizard.appDescriptor = reddit; [wizard initializeFields];
        Check([wizard.countryField.text isEqual:@""] && wizard.roleControl.selectedSegmentIndex == 0, @"unset preferences preserve Auto and the default role");
        launcher.appDescriptor = facebook; launcher.presented = nil; launcher.capturedValues = nil; [launcher createContainer];
        Check(!launcher.presented && !launcher.capturedValues && launcher.errorMessage.length, @"default preferences cannot admit inactive Facebook creation");
        printf("PASS creation defaults: %lu checks; shipped normal create enters scoped wizard without IPC, advanced create and wizard fields consume defaults; draft/Auto overrides and inactive Facebook gate retained\n", (unsigned long)Checks);
    } @catch (NSException *failure) {
        fprintf(stderr, "FAIL creation defaults: %s\n", failure.reason.UTF8String); return 1;
    } @finally { [fixtureDefaults removePersistentDomainForName:suite]; }
} return 0; }
'''
code = code.replace("NSUserDefaults.standardUserDefaults", "fixtureDefaults")
with tempfile.TemporaryDirectory(prefix="rbx-creation-defaults-") as directory:
    fixture = Path(directory) / "fixture.m"
    fixture.write_text(code)
    executable = Path(directory) / "fixture"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Wno-unused-parameter",
                    "-Werror", "-I" + str(ROOT / "launcher"), "-I" + str(ROOT / "shared"),
                    "-framework", "Foundation", str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
