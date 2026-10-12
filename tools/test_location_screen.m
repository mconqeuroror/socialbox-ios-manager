#import <Foundation/Foundation.h>
#import "RBXLocationDraft.h"
#import "RBXScreenRecommendation.h"
static NSUInteger checks;
static void check(BOOL condition,NSString *message) { checks++; if (!condition) { fprintf(stderr,"FAIL %s\n",message.UTF8String); exit(1); } }
int main(void) { @autoreleasepool {
    NSDictionary *catalog=@{@"countryCities":@{@"US":@[@{@"city":@"New York",@"lat":@"40.7128",@"lon":@"-74.0060",@"timezone":@"America/New_York"}],
        @"CA":@[@{@"city":@"Toronto",@"lat":@"43.6532",@"lon":@"-79.3832",@"timezone":@"America/Toronto"}]}};
    NSDictionary *d=RBXLocationDraft(catalog,@"US",@"40.7200",@"-74.0000",@"US",@"US",NO);
    check([d[@"valid"] boolValue]&&[d[@"city"] isEqual:@"New York"]&&[d[@"timezone"] isEqual:@"America/New_York"],@"near-city coordinates resolve coherent city/timezone");
    check([d[@"latitude"] isEqual:@"40.720000"],@"explicit coordinates retained, not silently snapped");
    NSDictionary *edge=RBXLocationDraft(catalog,@"US",@"40.7128",@"-74.036999999",@"US",@"US",NO);
    check(![edge[@"valid"] boolValue]||fabs([edge[@"longitude"] doubleValue]-(-74.006))<=.031,@"validation uses the exact serialized coordinate the daemon will check");
    for (id value in @[@"",@"NaN",@"Inf",@"40.7junk",@"91",@YES,NSNull.null])
        check(![RBXLocationDraft(catalog,@"US",value,@"-74",@"US",@"US",NO)[@"valid"] boolValue],@"malformed/nonfinite/out-of-range latitude rejected");
    for (id value in @[@"-181",@"180.1",@"-74abc",@"-Infinity"])
        check(![RBXLocationDraft(catalog,@"US",@"40.7",value,@"US",@"US",NO)[@"valid"] boolValue],@"invalid longitude rejected");
    check(![RBXLocationDraft(catalog,@"US",@"40.7528",@"-74.0060",@"US",@"US",NO)[@"valid"] boolValue],@"existing daemon city radius retained");
    check(![RBXLocationDraft(catalog,@"US",@"43.6532",@"-79.3832",@"US",@"US",NO)[@"valid"] boolValue],@"foreign city cannot inherit country label");
    check(![RBXLocationDraft(catalog,@"US",@"40.7128",@"-74.0060",@"CA",@"US",NO)[@"valid"] boolValue],@"configured proxy mismatch blocks draft");
    check(![RBXLocationDraft(catalog,@"US",@"40.7128",@"-74.0060",@"US",@"CA",NO)[@"valid"] boolValue],@"observed proxy mismatch blocks draft");
    check(![RBXLocationDraft(catalog,@"US",@"40.7128",@"-74.0060",@"US",@"US",YES)[@"valid"] boolValue],@"used identity immutable");
    NSDictionary *unknown=RBXLocationDraft(catalog,@"US",@"40.7128",@"-74.0060",@"",@"",NO);
    check([unknown[@"valid"] boolValue]&&[unknown[@"reason"] containsString:@"not a live GPS or proxy verification"],@"absent proxy evidence never claimed as verified");
    NSDictionary *physical=@{@"nativeWidth":@1170,@"nativeHeight":@2532,@"logicalWidth":@390,@"logicalHeight":@844,@"scale":@3,@"nativeScale":@3};
    NSDictionary *exact=@{@"marketingName":@"Exact",@"screen":@{@"w":@1170,@"h":@2532,@"scale":@3}};
    NSDictionary *other=@{@"marketingName":@"Other",@"screen":@{@"w":@1179,@"h":@2556,@"scale":@3}};
    check([RBXScreenMatch(exact,physical)[@"exact"] boolValue],@"native/logical geometry and both scales match");
    check(![RBXScreenMatch(other,physical)[@"exact"] boolValue],@"close geometry is not exact");
    NSMutableDictionary *changed=physical.mutableCopy; changed[@"nativeScale"]=@2.88;
    check(![RBXScreenMatch(exact,changed)[@"exact"] boolValue],@"native downsampling mismatch is not exact");
    changed=physical.mutableCopy; changed[@"logicalWidth"]=@375;
    check(![RBXScreenMatch(exact,changed)[@"exact"] boolValue],@"Display Zoom logical mismatch is not exact");
    changed=physical.mutableCopy; changed[@"nativeWidth"]=@2532; changed[@"nativeHeight"]=@1170;
    changed[@"logicalWidth"]=@844; changed[@"logicalHeight"]=@390;
    check([RBXScreenMatch(exact,changed)[@"exact"] boolValue],@"landscape normalized");
    check(![RBXScreenMatch(@{},physical)[@"known"] boolValue],@"missing catalog data unverified");
    for (id bad in @[NSNull.null,@[],@YES,@"NaN",@"1170junk"]) {
        NSMutableDictionary *screen=[exact[@"screen"] mutableCopy]; screen[@"w"]=bad;
        check(![RBXScreenMatch(@{@"screen":screen},physical)[@"known"] boolValue],@"malformed catalog measurement remains unknown");
        changed=physical.mutableCopy; changed[@"logicalWidth"]=bad;
        check(![RBXScreenMatch(exact,changed)[@"known"] boolValue],@"malformed physical measurement remains unknown");
    }
    for (id bad in @[NSNull.null,@[],@42]) {
        check(![RBXScreenMatch(bad,physical)[@"known"] boolValue],@"non-object catalog model is unknown");
        check([RBXScreenModelOptions(@{@"invalid":bad},physical,@"") count]==0,@"non-object catalog rows skipped");
    }
    check([RBXScreenModelOptions((id)NSNull.null,physical,@"") count]==0,@"malformed whole catalog safely empty");
    changed=physical.mutableCopy; changed[@"nativeWidth"]=@(NAN);
    check(![RBXScreenMatch(exact,changed)[@"known"] boolValue],@"nonfinite metrics not ranked as valid");
    NSArray *options=RBXScreenModelOptions(@{@"iPhone1,1":exact,@"iPhone2,1":other},physical,@"iPhone2,1");
    check([options.firstObject[@"value"] isEqual:@"iPhone1,1"]&&[options.firstObject[@"group"] hasPrefix:@"Recommended"],@"matching model ranked before newer mismatched model");
    check([options.lastObject[@"selected"] boolValue]&&![options.firstObject[@"selected"] boolValue],@"ranking preserves current choice");
    NSDictionary *oldPhone=@{@"nativeWidth":@1125,@"nativeHeight":@2436,@"logicalWidth":@375,@"logicalHeight":@812,@"scale":@3,@"nativeScale":@3};
    options=RBXScreenModelOptions(@{@"iPhone1,1":exact,@"iPhone2,1":other},oldPhone,@"");
    check([options.firstObject[@"group"] containsString:@"not an exact match"],@"iPhone X without catalog exact candidate truthfully approximate");
    check([RBXScreenModelOptions(@{},physical,@"") count]==0,@"empty catalog yields no invented recommendation");
    printf("PASS %lu location and screen-geometry assertions\n",(unsigned long)checks);
} return 0; }
