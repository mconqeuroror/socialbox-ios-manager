#!/usr/bin/env python3
"""Execute the shipped Remove passcode action with inert UI/Keychain seams."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "launcher/RBXLauncherViewController.m").read_text()
marker = '[sheet addAction:[UIAlertAction actionWithTitle:@"Remove passcode"'
assert source.count(marker) == 1
start = source.index(marker)
action = source[start:source.index('}]];', start) + len('}]];')]

fixture = r'''
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, UIAlertActionStyle) { UIAlertActionStyleDestructive = 2 };
@interface UIAlertAction : NSObject
@property(nonatomic,copy) NSString *title;
@property(nonatomic) UIAlertActionStyle style;
@property(nonatomic,copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action=[self new]; action.title=title; action.style=style; action.handler=handler; return action;
}
@end
@interface Sheet : NSObject
@property(nonatomic,strong) UIAlertAction *action;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation Sheet
- (void)addAction:(UIAlertAction *)action { self.action=action; }
@end
static BOOL clearSucceeds;
static NSError *clearError;
static NSUInteger clearCalls, checks, failures;
@interface RBXPasscodeStore : NSObject
+ (BOOL)clearPasscode:(NSError **)error;
@end
@implementation RBXPasscodeStore
+ (BOOL)clearPasscode:(NSError **)error {
    clearCalls++; if (!clearSucceeds && error) *error=clearError; return clearSucceeds;
}
@end
@interface Controller : NSObject
@property(nonatomic,strong) Sheet *sheet;
@property(nonatomic,copy) NSString *messageTitle;
@property(nonatomic,copy) NSString *messageDetail;
@property(nonatomic) NSUInteger messageCalls;
- (void)installRemovalAction;
- (void)showMessage:(NSString *)title detail:(NSString *)detail;
@end
@implementation Controller
- (void)installRemovalAction {
    Sheet *sheet=[Sheet new]; self.sheet=sheet;
    __ACTION__
}
- (void)showMessage:(NSString *)title detail:(NSString *)detail {
    self.messageCalls++; self.messageTitle=title; self.messageDetail=detail;
}
@end
static void Check(BOOL ok, NSString *message) {
    checks++; if (!ok) { failures++; fprintf(stderr,"FAIL passcode removal: %s\n",message.UTF8String); }
}
int main(void) { @autoreleasepool {
    for (NSUInteger scenario=0; scenario<3; scenario++) {
        clearSucceeds=scenario==0;
        clearError=scenario==1 ? [NSError errorWithDomain:@"fixture" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Keychain deletion denied."}] : nil;
        clearCalls=0; Controller *controller=[Controller new]; [controller installRemovalAction];
        UIAlertAction *action=controller.sheet.action;
        Check(action && [action.title isEqual:@"Remove passcode"] && action.style==UIAlertActionStyleDestructive,@"actual operator action is installed");
        Check(clearCalls==0 && controller.messageCalls==0,@"merely presenting settings must not clear the gate or report an outcome");
        action.handler(action);
        Check(clearCalls==1,@"one explicit operator action performs exactly one clear attempt");
        if (scenario==0) Check(controller.messageCalls==0,@"successful removal does not report an error");
        else {
            Check(controller.messageCalls==1 && [controller.messageTitle isEqual:@"Passcode not removed"],@"failed removal is reported once");
            Check([controller.messageDetail isEqual:scenario==1 ? @"Keychain deletion denied." : @"Could not remove the passcode. Try again."],@"provider detail or a useful fallback reaches the operator");
        }
    }
    printf("%lu actual removal-action checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures);
    return failures ? 1 : 0;
}}
'''.replace('__ACTION__', action)
with tempfile.TemporaryDirectory(prefix='rbx-passcode-removal-') as temp:
    folder = Path(temp)
    native = folder / 'fixture.m'
    native.write_text(fixture)
    executable = folder / 'test'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    str(native), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
