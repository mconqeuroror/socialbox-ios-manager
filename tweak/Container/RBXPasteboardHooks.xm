#import "RBXHookInstallation.h"
#import "RBXPasteboardHooks.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <UIKit/UIPasteboard.h>
#import <objc/runtime.h>

static UIPasteboard *sPrivateView;
static BOOL sSystemClipboardAllowed;
static IMP sOriginalGeneralPasteboard;

%group RBXPasteboardFactories

%hook UIPasteboard
+ (UIPasteboard *)generalPasteboard { return sPrivateView; }
+ (UIPasteboard *)pasteboardWithUniqueName { return nil; }

+ (UIPasteboard *)pasteboardWithName:(UIPasteboardName)pasteboardName
                              create:(BOOL)create {
    (void)pasteboardName; (void)create;
    return nil;
}
+ (void)removePasteboardWithName:(UIPasteboardName)pasteboardName {
    (void)pasteboardName;
}
%end
%end

%group RBXPasteboardInstances
%hook UIPasteboard

- (UIPasteboardName)name { return @"com.redditbox.private-clipboard"; }
- (BOOL)isPersistent { return NO; }
- (void)setPersistent:(BOOL)persistent { }
- (NSInteger)changeCount { return 0; }
- (NSInteger)numberOfItems { return 0; }
- (NSArray<NSItemProvider *> *)itemProviders { return @[]; }
- (void)setItemProviders:(NSArray<NSItemProvider *> *)providers { }
- (void)setItemProviders:(NSArray<NSItemProvider *> *)providers localOnly:(BOOL)localOnly
    expirationDate:(NSDate *)date { }
- (void)setObjects:(NSArray<id<NSItemProviderWriting>> *)objects { }
- (void)setObjects:(NSArray<id<NSItemProviderWriting>> *)objects localOnly:(BOOL)localOnly
    expirationDate:(NSDate *)date { }
- (NSArray<NSString *> *)pasteboardTypes { return @[]; }
- (BOOL)containsPasteboardTypes:(NSArray<NSString *> *)types { return NO; }
- (NSArray<NSArray<NSString *> *> *)pasteboardTypesForItemSet:(NSIndexSet *)items { return @[]; }
- (BOOL)containsPasteboardTypes:(NSArray<NSString *> *)types inItemSet:(NSIndexSet *)items { return NO; }
- (NSIndexSet *)itemSetWithPasteboardTypes:(NSArray<NSString *> *)types { return [NSIndexSet indexSet]; }
- (NSArray *)valuesForPasteboardType:(NSString *)type inItemSet:(NSIndexSet *)items { return @[]; }
- (NSArray<NSData *> *)dataForPasteboardType:(NSString *)type inItemSet:(NSIndexSet *)items { return @[]; }
- (void)addItems:(NSArray<NSDictionary<NSString *, id> *> *)items { }
- (void)setItems:(NSArray<NSDictionary<NSString *, id> *> *)items options:(NSDictionary *)options { }
- (NSArray<NSURL *> *)URLs { return @[]; }
- (void)setURLs:(NSArray<NSURL *> *)URLs { }
- (NSArray<UIImage *> *)images { return @[]; }
- (void)setImages:(NSArray<UIImage *> *)images { }
- (UIColor *)color { return nil; }
- (void)setColor:(UIColor *)color { }
- (NSArray<UIColor *> *)colors { return @[]; }
- (void)setColors:(NSArray<UIColor *> *)colors { }
- (BOOL)hasStrings { return NO; }
- (BOOL)hasURLs { return NO; }
- (BOOL)hasImages { return NO; }
- (BOOL)hasColors { return NO; }
- (void)detectPatternsForPatterns:(NSSet<UIPasteboardDetectionPattern> *)patterns
    completionHandler:(void (^)(NSSet<UIPasteboardDetectionPattern> *, NSError *))completion {
    if (completion) completion([NSSet set], nil);
}
- (void)detectPatternsForPatterns:(NSSet<UIPasteboardDetectionPattern> *)patterns
    inItemSet:(NSIndexSet *)items
    completionHandler:(void (^)(NSArray<NSSet<UIPasteboardDetectionPattern> *> *, NSError *))completion {
    if (completion) completion(@[], nil);
}
- (void)detectValuesForPatterns:(NSSet<UIPasteboardDetectionPattern> *)patterns
    completionHandler:(void (^)(NSDictionary<UIPasteboardDetectionPattern, id> *, NSError *))completion {
    if (completion) completion(@{}, nil);
}
- (void)detectValuesForPatterns:(NSSet<UIPasteboardDetectionPattern> *)patterns
    inItemSet:(NSIndexSet *)items
    completionHandler:(void (^)(NSArray<NSDictionary<UIPasteboardDetectionPattern, id> *> *, NSError *))completion {
    if (completion) completion(@[], nil);
}

- (NSArray<NSDictionary<NSString *, id> *> *)items { return @[]; }
- (void)setItems:(NSArray<NSDictionary<NSString *, id> *> *)items { (void)items; }
- (NSString *)string { return nil; }
- (void)setString:(NSString *)string { (void)string; }
- (NSArray<NSString *> *)strings { return @[]; }
- (void)setStrings:(NSArray<NSString *> *)strings { (void)strings; }
- (UIImage *)image { return nil; }
- (void)setImage:(UIImage *)image { (void)image; }
- (NSURL *)URL { return nil; }
- (void)setURL:(NSURL *)URL { (void)URL; }
- (NSData *)dataForPasteboardType:(NSString *)pasteboardType {
    (void)pasteboardType;
    return nil;
}
- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    (void)data; (void)pasteboardType;
}
- (id)valueForPasteboardType:(NSString *)pasteboardType {
    (void)pasteboardType;
    return nil;
}
- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    (void)value; (void)pasteboardType;
}

%end
%end

BOOL RBXInstallPasteboardHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Obtain the object without reading or writing its contents. UIKit can
        // return a subclass, so install the blocking instance methods there too.
        sPrivateView = UIPasteboard.generalPasteboard;
        RBXContainerManager *manager = RBXContainerManager.sharedManager;
        sSystemClipboardAllowed = manager.validatedProfileLoaded &&
            [[manager.currentProfile valueForPath:@"security.systemClipboard"] isEqual:@"enabled"];
        if (sSystemClipboardAllowed) {
            sOriginalGeneralPasteboard = method_getImplementation(
                class_getClassMethod(UIPasteboard.class, @selector(generalPasteboard)));
            RBXLog("system clipboard compatibility enabled for container %@; cross-profile pasteboard isolation is disabled", manager.containerId);
            return;
        }
        Class concrete = object_getClass(sPrivateView);
        %init(RBXPasteboardInstances);
        if (concrete && concrete != UIPasteboard.class) {
            RBXMirrorBlockingHooksToSubclass(UIPasteboard.class, concrete);
        }
        %init(RBXPasteboardFactories);
        RBXLog("pasteboard channels blocked for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
    return RBXHookInstallationPassed();
}

BOOL RBXVerifyPasteboardHooks(void) {
    if (sSystemClipboardAllowed) {
        // Verify the explicitly selected compatibility policy without reading
        // clipboard contents or writing a test value into the user's clipboard.
        RBXContainerManager *manager = RBXContainerManager.sharedManager;
        return manager.validatedProfileLoaded && sPrivateView && sOriginalGeneralPasteboard &&
            [[manager.currentProfile valueForPath:@"security.systemClipboard"] isEqual:@"enabled"] &&
            method_getImplementation(class_getClassMethod(UIPasteboard.class,
                @selector(generalPasteboard))) == sOriginalGeneralPasteboard;
    }
    if (!RBXHookInstallationPassed() || !sPrivateView) return NO;
    UIPasteboard *board = UIPasteboard.generalPasteboard;
    if (board != sPrivateView || board.numberOfItems || board.changeCount || board.isPersistent ||
        board.items.count || board.itemProviders.count || board.pasteboardTypes.count ||
        board.string || board.strings.count || board.URL || board.URLs.count ||
        board.image || board.images.count || board.color || board.colors.count ||
        board.hasStrings || board.hasURLs || board.hasImages || board.hasColors) return NO;
    NSArray *types = @[@"public.utf8-plain-text", @"public.url", @"public.png"];
    NSIndexSet *items = [NSIndexSet indexSetWithIndex:0];
    if ([board containsPasteboardTypes:types] || [board containsPasteboardTypes:types inItemSet:items] ||
        [board pasteboardTypesForItemSet:items].count || [board itemSetWithPasteboardTypes:types].count ||
        [board valuesForPasteboardType:types[0] inItemSet:items].count ||
        [board dataForPasteboardType:types[0] inItemSet:items].count ||
        [board valueForPasteboardType:types[0]] || [board dataForPasteboardType:types[0]]) return NO;
    __block NSUInteger callbacks = 0;
    __block BOOL empty = YES;
    NSSet *patterns = [NSSet setWithObject:UIPasteboardDetectionPatternProbableWebURL];
    [board detectPatternsForPatterns:patterns completionHandler:^(NSSet *result, NSError *error) {
        callbacks++; empty = empty && result != nil && result.count == 0 && !error;
    }];
    [board detectPatternsForPatterns:patterns inItemSet:items completionHandler:^(NSArray *result, NSError *error) {
        callbacks++; empty = empty && result != nil && result.count == 0 && !error;
    }];
    [board detectValuesForPatterns:patterns completionHandler:^(NSDictionary *result, NSError *error) {
        callbacks++; empty = empty && result != nil && result.count == 0 && !error;
    }];
    [board detectValuesForPatterns:patterns inItemSet:items completionHandler:^(NSArray *result, NSError *error) {
        callbacks++; empty = empty && result != nil && result.count == 0 && !error;
    }];
    // No write probe: a broken installation must never overwrite the user's
    // clipboard merely to prove its own failure. Setter IMPs were checked above.
    return empty && callbacks == 4;
}
