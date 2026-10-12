#!/usr/bin/env python3
"""Execute actual sensor installation/verification with early UIKit access forbidden."""
from pathlib import Path
import subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
s = (ROOT / 'tweak/Identity/RBXSensorHooks.xm').read_text()
body = s[s.index('BOOL RBXInstallSensorHooks(void) {'):].replace('%init;', 'installed = YES;')
harness = r'''#import <Foundation/Foundation.h>
#include <stdlib.h>
static BOOL installed, allowUIKit, displayValid=YES, hookValid=YES, sSensorsBlocked, sVerified;
static int hardwareCalls;
#define RBXLog(...) ((void)0)
typedef struct { double width,height; } FixtureSize;
typedef struct { FixtureSize size; } FixtureRect;
@interface RBXDeviceProfile : NSObject
@property NSString *containerId;
- (id)valueForPath:(NSString *)path;
@end
@implementation RBXDeviceProfile
- (id)valueForPath:(NSString *)path { return @{@"security.sensorAccess":@"blocked",@"device.screen.w":@1170,@"device.screen.h":@2532,@"device.screen.scale":@3,@"device.screen.fps":@60}[path]; }
@end
static RBXDeviceProfile *RBXSensorProfile(void) { static RBXDeviceProfile *p; if(!p)p=[RBXDeviceProfile new];return p; }
static BOOL RBXHookInstallationPassed(void) { return hookValid; }
@interface CMMotionManager : NSObject
@property BOOL accelerometerAvailable,gyroAvailable,magnetometerAvailable,deviceMotionAvailable;
@property id accelerometerData,gyroData,magnetometerData,deviceMotion;
@end
@implementation CMMotionManager
- (instancetype)init { if(!allowUIKit){fputs("FAIL: hardware object created before application startup\n",stderr);exit(1);}hardwareCalls++;return [super init]; }
@end
@interface UIScreen : NSObject
@property(readonly) FixtureRect nativeBounds;
@property(readonly) double scale;
@property(readonly) NSInteger maximumFramesPerSecond;
+ (instancetype)mainScreen;
@end
@implementation UIScreen
+ (instancetype)mainScreen { if(!allowUIKit){fputs("FAIL: UIKit screen accessed before application startup\n",stderr);exit(1);}hardwareCalls++;return [self new]; }
- (FixtureRect)nativeBounds { return (FixtureRect){{displayValid?1170:0,2532}}; }
- (double)scale { return 3; }
- (NSInteger)maximumFramesPerSecond { return 60; }
@end
''' + body + r'''
static void Check(BOOL ok,const char *message) { if(!ok){fprintf(stderr,"FAIL: %s\n",message);exit(1);} }
int main(int argc,char **argv) { @autoreleasepool {
 Check(RBXInstallSensorHooks(),"installer reports installed hooks");
 Check(installed && sSensorsBlocked && !sVerified && hardwareCalls==0,"installation leaves behavior unverified and avoids startup object creation");
 Check(RBXInstallSensorHooks() && hardwareCalls==0,"repeat install has no probes");
 allowUIKit=YES;
 if(argc>1 && !strcmp(argv[1],"bad-display"))displayValid=NO;
 if(argc>1 && !strcmp(argv[1],"bad-hook"))hookValid=NO;
 BOOL expected=displayValid&&hookValid;
 Check(RBXSensorHooksVerified()==expected,"deferred actual behavior result");
 Check(!expected || hardwareCalls==2,"valid behavior exercises real object APIs once");
 displayValid=NO;
 Check(!RBXSensorHooksVerified(),"verification does not reuse a stale PASS");
 puts("PASS actual sensor installation and deferred behavior");
} return 0; }
'''
entry=(ROOT/'tweak/RedditBox.xm').read_text()
# Scheduling the existing readiness call on main releases dyld's initializer lock.
with tempfile.TemporaryDirectory(prefix='rbx-sensor-startup-') as tmp:
 f=Path(tmp)/'fixture.m';f.write_text(harness);exe=Path(tmp)/'fixture'
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation',str(f),'-o',str(exe)],check=True)
 for mode in ('normal','bad-display','bad-hook'):subprocess.run([str(exe),mode],check=True)

assert 'dispatch_async(dispatch_get_main_queue(), ^{' in entry, 'readiness must run after the initializer returns'
