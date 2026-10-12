#!/usr/bin/env python3
"""Native presentation regressions: never turn cached receipts into live evidence,
and always deep-link Cloud into the registered app's configured server origin."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def function(path, signature):
    text = (ROOT / path).read_text()
    start = text.index(signature)
    return text[start:text.index('\n}\n', start) + 3]

status = function('launcher/RBXSettingsViewController.m', 'static NSDictionary *RBXSettingsStatusPresentation(')
url = function('launcher/RBXCloudVaultViewController.m', 'static NSURL *RBXCloudConsoleURL(')
source = r'''
#import <Foundation/Foundation.h>
#import "RBXSetupChecklist.h"
#import "RBXAppRegistry.h"
__FUNCTIONS__
static NSUInteger Checks;
static void Check(BOOL condition,NSString *message) {
    Checks++;
    if (!condition) {fprintf(stderr,"FAIL settings presentation: %s\n",message.UTF8String);exit(1);}
}
int main(void) { @autoreleasepool {
    double now=1000;
    NSMutableDictionary *license=[@{@"unlocked":@YES,@"expiresAt":@2000,@"serverURL":@"https://console.example"} mutableCopy];
    NSMutableDictionary *cloud=[@{@"ok":@YES,@"updatedAt":@900,@"serverHost":@"console.example"} mutableCopy];
    NSMutableDictionary *snapshot=[@{@"updatedAt":@1000,@"license":license,@"cloud":cloud} mutableCopy];
    NSDictionary *shown=RBXSettingsStatusPresentation(snapshot,now);
    Check([shown[@"licenseActive"] isEqual:@YES],@"Fresh signed activation is active");
    Check([shown[@"serverTitle"] isEqual:@"console.example"],@"Configured hostname shown without URL credentials");
    Check([shown[@"cloudReceiptAt"] isEqual:@900],@"Historical sync keeps its actual timestamp");
    Check(![shown.allValues containsObject:@"Connected"],@"Historical sync cannot claim a live connection");
    snapshot[@"updatedAt"]=@989;
    Check([RBXSettingsStatusPresentation(snapshot,now)[@"licenseActive"] isEqual:@NO],@"Stale daemon publication cannot stay green");
    snapshot[@"updatedAt"]=@1000;license[@"expiresAt"]=@1000;
    Check([RBXSettingsStatusPresentation(snapshot,now)[@"licenseActive"] isEqual:@NO],@"Expired activation cannot stay green");
    license[@"expiresAt"]=@2000;license[@"offlineGrace"]=@YES;
    Check([RBXSettingsStatusPresentation(snapshot,now)[@"licenseTitle"] isEqual:@"Offline grace"],@"Offline grace is distinguished from online connectivity");
    for (id badOrigin in @[@"http://console.example",@"https://user:secret@console.example",@"https://",NSNull.null]) {
        license[@"serverURL"]=badOrigin;
        Check([RBXSettingsStatusPresentation(snapshot,now)[@"serverConfigured"] isEqual:@NO],@"Unsafe or malformed origin stays unconfigured");
    }
    license[@"serverURL"]=@"https://console.example";cloud[@"serverHost"]=@"previous.example";
    Check([RBXSettingsStatusPresentation(snapshot,now)[@"cloudReceiptAt"] isEqual:@0],@"Old server's success cannot describe new server");
    cloud[@"serverHost"]=@"CONSOLE.EXAMPLE";
    Check([RBXSettingsStatusPresentation(snapshot,now)[@"cloudReceiptAt"] isEqual:@900],@"DNS hostname comparison is case insensitive");
    for (id timestamp in @[@YES,@1001,@0,NSNull.null]) {
        cloud[@"updatedAt"]=timestamp;
        Check([RBXSettingsStatusPresentation(snapshot,now)[@"cloudReceiptAt"] isEqual:@0],@"Malformed or future receipt has no displayed success date");
    }
    cloud[@"updatedAt"]=@900;cloud[@"ok"]=@NO;
    Check([RBXSettingsStatusPresentation(snapshot,now)[@"cloudReceiptOK"] isEqual:@NO],@"Failed historical sync remains failed");
    Check([RBXSettingsStatusPresentation(nil,now)[@"licenseActive"] isEqual:@NO],@"Missing status stays locked");
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        NSURL *link=RBXCloudConsoleURL(@"https://console.example:8443/old?secret=removed#old",descriptor);
        Check([link.path isEqual:[@"/apps/" stringByAppendingString:descriptor[@"appType"]]],@"Each registered app opens its own console section");
        Check([link.host isEqual:@"console.example"] && [link.port isEqual:@8443],@"Configured production origin is preserved");
        Check(!link.query && [link.fragment isEqual:@"cloud-backups"],@"Stale query and fragment are replaced");
    }
    for (id badOrigin in @[@"http://console.example",@"https://user:secret@console.example",@"javascript:alert(1)",@"https://",NSNull.null])
        Check(RBXCloudConsoleURL(badOrigin,RBXRedditAppDescriptor())==nil,@"Unsafe origin cannot open a web console");
    NSMutableDictionary *tampered=[RBXRedditAppDescriptor() mutableCopy];tampered[@"appType"]=@"../facebook";
    Check(RBXCloudConsoleURL(@"https://console.example",tampered)==nil,@"Unregistered route rejected");
    Check(RBXCloudConsoleURL(@"https://console.example",nil)==nil,@"Missing app rejected");
    printf("%lu settings status and Cloud routing checks, 0 failures\n",(unsigned long)Checks);
} return 0; }
'''.replace('__FUNCTIONS__', status + '\n' + url)
with tempfile.TemporaryDirectory(prefix='rbx-settings-presentation-') as temp:
    path=Path(temp)/'fixture.m';binary=Path(temp)/'fixture';path.write_text(source)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness',
                    '-I'+str(ROOT/'shared'),'-framework','Foundation',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
