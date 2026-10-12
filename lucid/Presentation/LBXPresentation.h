#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// No user identifiers, preferences, credentials, network state or license state.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LBXPresentationStatus(void);
FOUNDATION_EXPORT BOOL LBXPresentationMetadataSupported(NSDictionary *metadata,
                                                       NSString * _Nullable * _Nullable reason);
FOUNDATION_EXPORT BOOL LBXPresentationMethodMatches(Class cls, SEL selector,
                                                   const char *returnType, const char * _Nullable argumentType);
FOUNDATION_EXPORT BOOL LBXPresentationInstall(void);

#if LBX_PRESENTATION_FIXTURE
// Compiled only into the synthetic simulator app; absent from the device dylib.
FOUNDATION_EXPORT void LBXPresentationFixtureMetadata(NSDictionary *metadata);
FOUNDATION_EXPORT void LBXPresentationApplyFixture(UIViewController *controller);
#endif
NS_ASSUME_NONNULL_END
