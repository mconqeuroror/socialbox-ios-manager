#!/usr/bin/env python3
"""Executable producer policy using observed UA structure and synthetic values."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
header=ROOT/'shared/RBXFacebookUserAgent.h'
implementation='#import "RBXFacebookUserAgent.h"' if header.exists() else '''
static NSDictionary *RBXFacebookUAValuesForProfile(NSDictionary *p){return p;}
static NSString *RBXRewriteFacebookUserAgent(NSString *s,NSDictionary *v){return s;}
'''
fixture=r'''
#import <Foundation/Foundation.h>
__IMPLEMENTATION__
static NSUInteger Checks;
static void Check(BOOL v,NSString *m){Checks++;if(!v){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static NSDictionary *Profile(void){return @{@"containerId":@"fixture",@"appType":@"facebook",@"device":@{@"productType":@"iPhone17,1",@"iosVersion":@"18.0",@"buildVersion":@"22A3354",@"locale":@"en_US",@"screen":@{@"scale":@"3"}}};}
static NSString *Prefix(void){return @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_16 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/20H392 ";}
static NSString *UA(BOOL minimal){return [Prefix() stringByAppendingString:minimal?@"[FBAN/FBIOS;FBDV/iPhone10,4;FBMD/iPhone;FBSN/iOS;FBSV/16.7.16;FBSS/2;FBID/phone;FBLC/en_GB;FBOP/5;]":@"[FBAN/FBIOS;FBAV/578.1.0.71.72;FBBV/1063022819;FBDV/iPhone10,4;FBMD/iPhone;FBSN/iOS;FBSV/16.7.16;FBSS/2;FBID/phone;FBLC/en_GB;FBOP/5;FBRV/opaque-synthetic-revision;]" ];}
int main(void){@autoreleasepool{
 NSDictionary *profile=Profile(),*values=RBXFacebookUAValuesForProfile(profile);Check(values!=nil,@"selected app profile yields immutable replacement values");
 NSData *before=[NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingSortedKeys error:nil];
 for(NSNumber *minimal in @[@NO,@YES]){NSString *original=UA(minimal.boolValue),*rewritten=RBXRewriteFacebookUserAgent(original,values);
 Check([rewritten containsString:@"CPU iPhone OS 18_0 like Mac OS X"]&&[rewritten containsString:@"Mobile/22A3354 "],@"Mozilla OS and build follow selected profile");
 for(NSString *field in @[@"FBDV/iPhone17,1;",@"FBSV/18.0;",@"FBSS/3;",@"FBLC/en_US;",@"FBMD/iPhone;",@"FBSN/iOS;",@"FBID/phone;"])Check([rewritten containsString:field],@"Facebook identity field follows coherent profile");
 Check(![rewritten containsString:@"16_7_16"]&&![rewritten containsString:@"16.7.16"]&&![rewritten containsString:@"iPhone10,4"]&&![rewritten containsString:@"20H392"],@"observed physical fields no longer remain in rewritten UA");
 Check([rewritten containsString:@"Mozilla/5.0"]&&[rewritten containsString:@"AppleWebKit/605.1.15"]&&[rewritten containsString:@"FBOP/5;"],@"unmodified producer/engine metadata retained");
 if(!minimal.boolValue)Check([rewritten containsString:@"FBAV/578.1.0.71.72;FBBV/1063022819;"]&&[rewritten containsString:@"FBRV/opaque-synthetic-revision;"],@"real five-part app version/build and opaque revision preserved");
 else Check(![rewritten containsString:@"FBAV/"]&&![rewritten containsString:@"FBBV/"],@"minimal producer variant does not invent app version/build");
 Check([RBXRewriteFacebookUserAgent(rewritten,values) isEqual:rewritten],@"policy is idempotent");Check([original isEqual:UA(minimal.boolValue)],@"input string never mutated");
 }
 Check([before isEqual:[NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingSortedKeys error:nil]],@"profile is never mutated");
 for(id bad in @[NSNull.null,@42,@{},@"",@"unrelated-agent",[UA(NO) stringByAppendingString:@" suffix"],[UA(NO) stringByAppendingString:@"\n"],[UA(NO) stringByReplacingOccurrencesOfString:@"FBOP/5;" withString:@"FBOP/5;FBOP/6;"],[UA(NO) stringByReplacingOccurrencesOfString:@"FBOP/5;" withString:@"FBOP/5;FBAN/FBIOS;"],[UA(NO) stringByReplacingOccurrencesOfString:@"FBOP/5;" withString:@"FBOP/5;\r\nauthorization/secret;"],[UA(NO) stringByReplacingOccurrencesOfString:@"FBDV/iPhone10,4;" withString:@""],[UA(NO) stringByReplacingOccurrencesOfString:@"FBAN/FBIOS" withString:@"FBAN/Messenger"]])Check(!RBXRewriteFacebookUserAgent(bad,values),@"unsupported, ambiguous or header-injecting producer values fail closed");
 Check(!RBXRewriteFacebookUserAgent(nil,values)&&!RBXRewriteFacebookUserAgent(UA(NO),nil),@"missing source/config cannot yield a spoofed value");
 for(NSString *path in @[@"productType",@"iosVersion",@"buildVersion",@"locale"]){for(id bad in @[@"",@42,NSNull.null,@"bad\nvalue"]){NSMutableDictionary *p=[profile mutableCopy];NSMutableDictionary *d=[p[@"device"] mutableCopy];d[path]=bad;p[@"device"]=d;Check(!RBXFacebookUAValuesForProfile(p),@"invalid selected device fields are not interpolated into UA");}}
 for(id scale in @[@"",@"0",@"4",@"nan",@"3\n",@3,NSNull.null]){NSMutableDictionary *p=[profile mutableCopy];NSMutableDictionary *d=[p[@"device"] mutableCopy];d[@"screen"]=@{@"scale":scale};p[@"device"]=d;Check(!RBXFacebookUAValuesForProfile(p),@"unsupported screen scale rejected");}
 for(id app in @[@"reddit",@"unknown",@42,NSNull.null]){NSMutableDictionary *p=[profile mutableCopy];p[@"appType"]=app;Check(!RBXFacebookUAValuesForProfile(p),@"policy cannot target another app");}
 NSMutableDictionary *p=[profile mutableCopy];NSMutableDictionary *d=[p[@"device"] mutableCopy];d[@"iosVersion"]=@"26.0.1";d[@"buildVersion"]=@"23A355";d[@"locale"]=@"sk_SK";d[@"screen"]=@{@"scale":@"2.0"};p[@"device"]=d;
 NSString *ua=RBXRewriteFacebookUserAgent(UA(NO),RBXFacebookUAValuesForProfile(p));Check([ua containsString:@"CPU iPhone OS 26_0_1"]&&[ua containsString:@"FBSV/26.0.1;"]&&[ua containsString:@"FBLC/sk_SK;"]&&[ua containsString:@"FBSS/2;"],@"three-part iOS and canonical scale/locale supported without changing source app version");
 printf("PASS: %lu Facebook producer policy assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__IMPLEMENTATION__',implementation)
with tempfile.TemporaryDirectory(prefix='socialbox-facebook-ua-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness','-I'+str(ROOT/'shared'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
