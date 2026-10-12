#import <Foundation/Foundation.h>
#import "SBInterfaceCopy.h"

static NSUInteger Checks;
static NSMutableArray *Failures;
static void Check(BOOL pass, NSString *name) { Checks++; if(!pass) [Failures addObject:name]; }
int main(void) { @autoreleasepool {
    Failures=[NSMutableArray array]; NSDictionary *catalog=SBInterfaceTextCatalog();
    Check(catalog.count>=220,@"authored copy catalog populated");
    Check(![catalog isKindOfClass:NSMutableDictionary.class],@"catalog is immutable");
    Check(catalog==SBInterfaceTextCatalog(),@"catalog is stable readonly snapshot");
    for(NSString *key in catalog) {
        Check(SBUIHasText(key),@"every authored semantic key resolves");
        Check(SBUIText(key).length>0 && [SBUIText(key) isEqual:catalog[key]],@"resolved text exactly matches catalog");
        Check([key rangeOfString:@"."].location!=NSNotFound && [key rangeOfString:@" "].location==NSNotFound,@"semantic keys are component scoped");
    }
    Check([SBUIText(@"brand.name") isEqual:@"SocialBox"],@"brand text preserved");
    Check([SBUIText(@"identity.scope") containsString:@"They are not separate settings for the selected container."],@"identity scope preserved");
    Check([SBUIText(@"containers.create") isEqual:@"Create container"]&&[SBUIText(@"containers.empty") isEqual:@"No containers yet."],@"minimal Containers copy is direct");
    Check(!SBUIHasText(@"fixture.missing.secret-value"),@"missing key detectable");
    Check([SBUIText(@"fixture.missing.secret-value") isEqual:@"—"],@"missing key returns neutral text without exposing key");
    Check([SBUIContainerCount(0,0) isEqual:@"0 / 0"],@"zero container format");
    Check([SBUIContainerCount(12,345) isEqual:@"12 / 345"],@"typed container format");
    Check([SBUIAppCount(0) isEqual:@"Apps: 0"],@"zero app format");
    Check([SBUIAppCount(1) isEqual:@"Apps: 1"],@"singular app count remains natural");
    Check([SBUIAppCount(123456) isEqual:@"Apps: 123456"],@"typed app format");
    Check([SBUIContainerCount(NSUIntegerMax,NSUIntegerMax) isEqual:[NSString stringWithFormat:@"%lu / %lu",(unsigned long)NSUIntegerMax,(unsigned long)NSUIntegerMax]],@"large unsigned count preserved");
    NSDictionary *result=@{@"ok":@(!Failures.count),@"checks":@(Checks),@"entries":@(catalog.count),@"failures":Failures};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    [NSFileHandle.fileHandleWithStandardOutput writeData:data];
    return Failures.count ? 1 : 0;
} }
