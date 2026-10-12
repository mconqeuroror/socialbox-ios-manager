#!/usr/bin/env python3
"""LIFE-019 / ID-010: actual freeze admission with store fault injection.

The old implementation adapter uses the original post-OPEN publication block
and editor predicate verbatim, reproducing its ignored persistence failure.
The fixed helper is included directly. All metadata is synthetic and in memory.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
implementation = '#import "RBXIdentityLifecycle.h"\n'
if not (ROOT / "daemon/RBXIdentityLifecycle.h").exists():
    main = (ROOT / "daemon/main.m").read_text()
    position = main.index('entry[@"lastActiveAt"] =')
    start = main.rindex('[[RBXCentralStore sharedStore] update:', 0, position)
    block = main[start:main.index('        }];', position) + len('        }];')]
    block = block.replace('[RBXCentralStore sharedStore]', 'store')
    registry = (ROOT / "daemon/RBXContainerRegistry.m").read_text()
    start = registry.index('BOOL locked =', registry.index('- (BOOL)applyIdentityChoices:'))
    predicate = registry[start:registry.index(';', start) + 1]
    implementation = '''
static BOOL RBXFreezeIdentityBeforeLaunch(RBXCentralStore *store, NSString *container, NSError **error) {
    (void)error;
''' + block + '''
    return YES; // Old launch ignored the publication result before reporting success.
}
static BOOL RBXIdentityEntryIsFrozen(NSDictionary *stored) {
''' + predicate + '''
    return locked;
}
'''

fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXCentralStore.h"
__IMPLEMENTATION__
@interface FixtureStore : RBXCentralStore
@property(nonatomic) NSDictionary *document;
@property(nonatomic) BOOL failBeforeWrite, failAfterWrite;
@end
// Only the persistence boundary is replaced. The freeze mutation/predicate are
// actual production code; a commit-then-error models uncertain durability.
@implementation FixtureStore
- (BOOL)update:(void (^)(NSMutableDictionary *))block error:(NSError **)error {
    if (self.failBeforeWrite) {
        if (error) *error = [NSError errorWithDomain:@"fixture" code:28 userInfo:nil];
        return NO;
    }
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:self.document options:0 error:nil];
    NSMutableDictionary *next = [NSJSONSerialization JSONObjectWithData:bytes
        options:NSJSONReadingMutableContainers error:nil];
    block(next); self.document = next;
    if (self.failAfterWrite) {
        if (error) *error = [NSError errorWithDomain:@"fixture" code:5 userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)update:(void (^)(NSMutableDictionary *))block { [self update:block error:nil]; }
@end
static unsigned Cases, Failures;
static void Check(BOOL ok, NSString *message) {
    Cases++; if (!ok) { Failures++; fprintf(stderr,"FAIL: %s\n",message.UTF8String); }
}
static FixtureStore *Store(NSDictionary *entry) {
    FixtureStore *store = [FixtureStore new];
    store.document = @{ @"containers": entry ? @{ @"fresh":entry } : @{} };
    return store;
}
int main(void) { @autoreleasepool {
    FixtureStore *store = Store(@{@"nickname":@"retained", @"lastActiveAt":@0});
    NSError *error = nil;
    Check(RBXFreezeIdentityBeforeLaunch(store,@"fresh",&error) && !error,
          @"first freeze admitted after successful persistence");
    NSDictionary *entry = store.document[@"containers"][@"fresh"];
    NSNumber *marker = entry[@"identityFrozenAt"];
    Check(marker.doubleValue > 0 && [entry[@"lastActiveAt"] isEqual:@0] &&
          [entry[@"nickname"] isEqual:@"retained"], @"durable marker precedes open without claiming successful activity");
    Check(RBXIdentityEntryIsFrozen(entry), @"editor refuses mutation after admitted launch attempt");
    Check(RBXFreezeIdentityBeforeLaunch(store,@"fresh",&error) &&
          [store.document[@"containers"][@"fresh"][@"identityFrozenAt"] isEqual:marker], @"freeze is immutable across retries");
    store = Store(@{@"lastActiveAt":@0}); store.failBeforeWrite = YES; error = nil;
    Check(!RBXFreezeIdentityBeforeLaunch(store,@"fresh",&error) && error &&
          !store.document[@"containers"][@"fresh"][@"identityFrozenAt"], @"failed persistence prevents launch admission");
    store = Store(@{@"lastActiveAt":@0}); store.failAfterWrite = YES; error = nil;
    Check(!RBXFreezeIdentityBeforeLaunch(store,@"fresh",&error) && error,
          @"uncertain commit never authorizes launch");
    Check(RBXIdentityEntryIsFrozen(store.document[@"containers"][@"fresh"]),
          @"uncertain committed marker is retained conservatively");
    store = Store(nil); error = nil;
    Check(!RBXFreezeIdentityBeforeLaunch(store,@"fresh",&error) && error &&
          !store.document[@"containers"][@"fresh"], @"missing profile metadata cannot be invented by launch");
    store = Store(@{@"identityFrozenAt":@"invalid"}); error = nil;
    Check(!RBXFreezeIdentityBeforeLaunch(store,@"fresh",&error) && error,
          @"malformed marker cannot be overwritten into launch authority");
    Check(RBXIdentityEntryIsFrozen(@{@"identityFrozenAt":@"invalid"}), @"malformed marker does not unlock editor");
    Check(RBXIdentityEntryIsFrozen(@{@"lastActiveAt":@1}) && RBXIdentityEntryIsFrozen(@{@"lastLoginAt":@2}),
          @"legacy successful-use metadata remains frozen");
    Check(!RBXIdentityEntryIsFrozen(@{@"createdAt":@1}), @"new replacement identity remains editable before first admission");
    Check(RBXIdentityEntryIsFrozen(@{@"importedAt":@1,@"identityFrozenAt":@1}),
          @"restored same-account identity is frozen before first destination launch");
    printf("%s: %u identity freeze fault cases\n", Failures ? "FAIL" : "PASS", Cases);
    return Failures ? 1 : 0;
} }
'''.replace('__IMPLEMENTATION__', implementation)
with tempfile.TemporaryDirectory(prefix='rbx-identity-freeze-') as directory:
    source = pathlib.Path(directory) / 'test.m'
    binary = pathlib.Path(directory) / 'test'
    source.write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness',
                    '-Wno-deprecated-declarations','-I'+str(ROOT/'daemon'),'-I'+str(ROOT/'shared'),
                    '-framework','Foundation',str(source),str(ROOT/'daemon/RBXCentralStore.m'),
                    '-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)

# Native failure tests above verify semantics. These integration checks ensure
# the checked admission remains before the first process/lease authority and
# successful-open UI metadata retains its original meaning.
if (ROOT / 'daemon/RBXIdentityLifecycle.h').exists():
    main = (ROOT / 'daemon/main.m').read_text()
    launch = main[main.index('static void handleLaunchContainer'):main.index('static void darwinCallback')]
    assert launch.index('if (!RBXFreezeIdentityBeforeLaunch') < launch.index('armTrafficForContainer:')
    assert launch.index('if (!RBXFreezeIdentityBeforeLaunch') < launch.index('launchCloneForProfile:')
    assert launch.index('openTrafficForContainer:') < launch.index('entry[@"lastActiveAt"] =')
    registry = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()
    assert registry.count('RBXIdentityEntryIsFrozen(stored)') == 2
    cloud = (ROOT / 'daemon/RBXCloudSync.m').read_text()
    assert '@"identityFrozenAt": @(now)' in cloud
    print('PASS: freeze admission/editor/restore integration order')
