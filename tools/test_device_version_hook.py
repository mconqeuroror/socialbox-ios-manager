#!/usr/bin/env python3
"""Execute the shipped version hook body with an observable inert original API.

This is a host behavior test, not device injection or an Apple API coverage claim.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "tweak/Identity/RBXDeviceHooks.xm").read_text()
signature = "- (NSOperatingSystemVersion)operatingSystemVersion {"
start = source.index(signature)
end = source.index("\n- (NSString *)operatingSystemVersionString", start)
method = source[start:end].replace("%orig", "RBXOriginalVersion()")
harness = r'''
#import <Foundation/Foundation.h>
@interface FixtureProfile : NSObject
@property(nonatomic, copy) NSString *iosVersion;
@end
@implementation FixtureProfile
@end
static FixtureProfile *profile;
static NSUInteger originalCalls;
static FixtureProfile *rbxProfile(void) { return profile; }
static NSOperatingSystemVersion RBXOriginalVersion(void) {
    originalCalls++;
    return (NSOperatingSystemVersion){99,88,77};
}
@interface FixtureProcess : NSObject
- (NSOperatingSystemVersion)operatingSystemVersion;
@end
@implementation FixtureProcess
''' + method + r'''
@end
static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL device version hook: %s\n", message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    profile = [FixtureProfile new]; FixtureProcess *process = [FixtureProcess new];
    for (NSArray *row in @[@[@"26.5",@26,@5,@0], @[@"26.6",@26,@6,@0],
        @[@"18.7.8",@18,@7,@8], @[@"26.6.2",@26,@6,@2]]) {
        profile.iosVersion = row[0]; originalCalls = 0;
        NSOperatingSystemVersion version = [process operatingSystemVersion];
        Check(originalCalls == 0, [NSString stringWithFormat:@"%@ must not call the physical original API", row[0]]);
        Check(version.majorVersion == [row[1] integerValue] && version.minorVersion == [row[2] integerValue] &&
              version.patchVersion == [row[3] integerValue], @"selected profile version must be returned, with omitted patch zero");
    }
    for (id bad in @[@"",@"26",@"26.5.2.1",@"26..5",@"26.5beta",@"-26.5",@"+26.5",@" 26.5",@"26.5 ",
                      @"99999999999999999999999.1", NSNull.null]) {
        profile.iosVersion = bad == NSNull.null ? nil : bad; originalCalls = 0;
        NSOperatingSystemVersion version = [process operatingSystemVersion];
        Check(originalCalls == 1 && version.majorVersion == 99, @"invalid/missing profile version retains existing original fallback");
    }
    puts("PASS device version hook: selected two/three-part versions return without original calls; malformed versions retain fallback");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix="rbx-device-version-") as directory:
    fixture = Path(directory) / "fixture.m"
    fixture.write_text(harness)
    executable = Path(directory) / "fixture"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                    str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
