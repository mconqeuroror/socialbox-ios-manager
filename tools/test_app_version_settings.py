#!/usr/bin/env python3
"""Execute shipped version-settings save with controlled native file I/O.

Only the NSMutableDictionary provider is replaced in the extracted method. Its
parsing, mutation order, error presentation and daemon action remain unchanged.
No user preference files or daemon are accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "launcher/RBXSettingsViewController.m").read_text()
method = source[source.index("- (void)saveAppVersionSettings {"):source.index("- (void)closeWizard {")]
method = method.replace("NSMutableDictionary", "FixtureSettingsDictionary")
code = r'''
#import <Foundation/Foundation.h>
static NSDictionary *storedSettings;
static BOOL allowWrite, writeSucceeded, notifiedBeforeSave;
static NSUInteger reads, writes, notifications, checks, failures;
static NSString *const RBXAppVersionPrefsPath = @"/inert-fixture/preferences.plist";

// NSMutableDictionary's primitives preserve real subscripting/remove behavior.
// Only disk read/write results are controlled by the fixture.
@interface FixtureSettingsDictionary : NSMutableDictionary
@property NSMutableDictionary *backing;
+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path;
@end
@implementation FixtureSettingsDictionary
- (instancetype)init { self = [super init]; if (self) _backing = [NSMutableDictionary new]; return self; }
+ (instancetype)dictionary { return [self new]; }
+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path {
    reads++; if (!storedSettings) return nil;
    FixtureSettingsDictionary *value = [self new]; [value.backing addEntriesFromDictionary:storedSettings]; return value;
}
- (NSUInteger)count { return self.backing.count; }
- (NSEnumerator *)keyEnumerator { return self.backing.keyEnumerator; }
- (id)objectForKey:(id)key { return self.backing[key]; }
- (void)setObject:(id)value forKey:(id<NSCopying>)key { [self.backing setObject:value forKey:key]; }
- (void)removeObjectForKey:(id)key { [self.backing removeObjectForKey:key]; }
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)atomic {
    writes++; if (!allowWrite) return NO;
    storedSettings = [self.backing copy]; writeSucceeded = YES; return YES;
}
@end

@interface FixtureField : NSObject
@property NSString *text;
@end
@implementation FixtureField
@end
@interface FixtureSettings : NSObject
@property NSDictionary *appDescriptor;
@property FixtureField *latestVersionField, *versionIntervalField;
@property NSString *errorTitle, *errorDetail, *submittedAction;
- (void)saveAppVersionSettings;
- (void)showMessage:(NSString *)title detail:(NSString *)detail;
- (NSString *)appText:(NSString *)text;
- (void)submitAction:(NSString *)action values:(NSDictionary *)values;
@end
@implementation FixtureSettings
- (void)showMessage:(NSString *)title detail:(NSString *)detail { self.errorTitle = title; self.errorDetail = detail; }
- (NSString *)appText:(NSString *)text { return text; }
- (void)submitAction:(NSString *)action values:(NSDictionary *)values { notifications++; notifiedBeforeSave |= !writeSucceeded; self.submittedAction = action; }
''' + method + r'''
@end

static void Check(BOOL result, NSString *message) {
    checks++; if (!result) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
static FixtureSettings *Reset(void) {
    storedSettings = @{@"latestKnownVersion":@"2026.35.0", @"checkIntervalHours":@24,
        @"unrelatedPreference":@"keep", @"nested":@{@"unchanged":@YES}};
    reads = writes = notifications = 0; allowWrite = YES; writeSucceeded = notifiedBeforeSave = NO;
    FixtureSettings *settings = [FixtureSettings new]; settings.appDescriptor = @{@"appType":@"reddit"};
    settings.latestVersionField = [FixtureField new]; settings.latestVersionField.text = @"2026.36.0";
    settings.versionIntervalField = [FixtureField new]; settings.versionIntervalField.text = @"48";
    return settings;
}
int main(void) { @autoreleasepool {
    FixtureSettings *settings = Reset(); allowWrite = NO;
    NSDictionary *before = storedSettings;
    settings.versionIntervalField.text = @"048";
    [settings saveAppVersionSettings];
    Check(writes == 1 && notifications == 0, @"failed atomic write must not notify the daemon");
    Check([storedSettings isEqual:before], @"failed write preserves all stored settings");
    Check(settings.errorTitle.length && [settings.errorDetail.lowercaseString containsString:@"try again"], @"write failure displays an actionable retry error");
    Check([settings.versionIntervalField.text isEqual:@"048"], @"failed write preserves the operator's draft text");

    for (NSString *invalid in @[@"", @"abc", @"1.5", @"0", @"721", @"-1", @"+1", @"1e2", @"12hours", @"1 2", @"999999999999999999999999999999999999"]) {
        settings = Reset(); before = storedSettings; settings.versionIntervalField.text = invalid;
        [settings saveAppVersionSettings];
        Check(reads == 0 && writes == 0 && notifications == 0 && [storedSettings isEqual:before], [@"invalid interval has zero persistence or daemon effects: " stringByAppendingString:invalid]);
        Check(settings.errorTitle.length && [settings.errorDetail containsString:@"1"] && [settings.errorDetail containsString:@"720"], @"invalid interval explains the supported integer range");
    }
    for (NSString *valid in @[@"1", @"720", @"24", @" 48 ", @"001"]) {
        settings = Reset(); settings.versionIntervalField.text = valid;
        [settings saveAppVersionSettings];
        Check(writes == 1 && notifications == 1 && !notifiedBeforeSave && [settings.submittedAction isEqual:@"appVersionConfigurationChanged"], @"valid interval persists before sending one configuration action");
        Check([storedSettings[@"checkIntervalHours"] integerValue] == valid.integerValue && !settings.errorTitle, @"valid integer hours persist without fallback coercion");
        Check([storedSettings[@"unrelatedPreference"] isEqual:@"keep"] && [storedSettings[@"nested"] isEqual:@{@"unchanged":@YES}], @"saving monitoring settings preserves unrelated preferences");
    }
    for (NSString *invalidVersion in @[@"2026", @"v2026.35.0", @"2026.35.beta", @"1.2.3.4.5"]) {
        settings = Reset(); before = storedSettings; settings.latestVersionField.text = invalidVersion;
        [settings saveAppVersionSettings];
        Check(reads == 0 && writes == 0 && notifications == 0 && [storedSettings isEqual:before] && [settings.errorTitle isEqual:@"Invalid version"], @"existing numeric version override validation is retained");
    }
    settings = Reset(); settings.latestVersionField.text = @" \n ";
    [settings saveAppVersionSettings];
    Check(!storedSettings[@"latestKnownVersion"] && [storedSettings[@"unrelatedPreference"] isEqual:@"keep"] && notifications == 1, @"blank version removes only the override and notifies after saving");
    settings = Reset(); settings.latestVersionField.text = @" 2026.36.0 ";
    [settings saveAppVersionSettings];
    Check([storedSettings[@"latestKnownVersion"] isEqual:@"2026.36.0"], @"valid version override is trimmed before persistence");
    settings = Reset(); storedSettings = nil;
    [settings saveAppVersionSettings];
    Check(writes == 1 && notifications == 1 && [storedSettings[@"checkIntervalHours"] isEqual:@48], @"missing preferences can be initialized through the same save path");
    settings = Reset(); before = storedSettings; settings.appDescriptor = @{@"appType":@"facebook"};
    settings.latestVersionField.text = @"bad"; settings.versionIntervalField.text = @"abc";
    [settings saveAppVersionSettings];
    Check(reads == 0 && writes == 0 && notifications == 0 && !settings.errorTitle && [storedSettings isEqual:before], @"Facebook guard has no file, daemon or error-presentation effects");
    printf("%lu app-version settings checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
'''
with tempfile.TemporaryDirectory(prefix="rbx-app-version-settings-") as directory:
    fixture = Path(directory) / "fixture.m"
    fixture.write_text(code)
    executable = Path(directory) / "fixture"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                    "-Wno-unused-parameter", "-Werror", "-framework", "Foundation",
                    str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
