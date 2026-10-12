#import "SBBlueProgressAddon.h"
#import "../Presentation/SBBackendAdapter.h"
#import "../Presentation/SBSwitchProgress.h"
#import "../Presentation/SBDesign.h"
#import "../HelperSafety/LBXCallerFile.h"
#import "../Switching/LBXSocialBoxProduct.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#include <unistd.h>

static NSString *const ManagerPath=@LBX_SOCIALBOX_MANAGER_PATH;
static NSString *const ManagerSHA=@LBX_SOCIALBOX_MANAGER_SHA256;
static NSString *const PriorOverlayPath=@"/var/jb/Library/MobileSubstrate/DynamicLibraries/LBXPresentation.dylib";
static NSString *const PriorOverlaySHA=@"a0423c7c92dbbe49b700bce7605fa7a9edb9e1d2cf5d70bb9d658137f78972d8";
static NSString *const AddonPath=@"/var/jb/Library/MobileSubstrate/DynamicLibraries/SBBlueProgress.dylib";
#if SB_BLUE_PROGRESS_TESTING
static BOOL FixturePins;
static NSDictionary *FixtureMetadata;
void SBBlueProgressFixturePins(BOOL current) { FixturePins=current; }
void SBBlueProgressFixtureMetadata(NSDictionary *metadata) { FixtureMetadata=[metadata copy]; }
#endif

static BOOL ImageAt(const void *symbol,NSString *path) {
    Dl_info info={0};
    return symbol && dladdr(symbol,&info) && info.dli_fname &&
        [@(info.dli_fname).stringByResolvingSymlinksInPath isEqual:path.stringByResolvingSymlinksInPath];
}
static BOOL CurrentProfile(void) {
    if(!NSThread.isMainThread)return NO;
    Class glyph=NSClassFromString(@"SBBlueProgressGlyph");
    const char *glyphImage=glyph?class_getImageName(glyph):NULL;
    if(!glyphImage)return NO;
#if SB_BLUE_PROGRESS_TESTING
    if(!FixturePins || ![@(glyphImage).stringByResolvingSymlinksInPath
        isEqual:NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath])return NO;
#else
    // Pinned historical file profile, not current device acceptance or mapped
    // byte attestation. Require fresh quiescent witnessed relaunch externally.
    if(getuid()!=501 || geteuid()!=0 ||
        ![NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath
            isEqual:ManagerPath.stringByResolvingSymlinksInPath] ||
        ![@(glyphImage).stringByResolvingSymlinksInPath isEqual:AddonPath.stringByResolvingSymlinksInPath] ||
        !ImageAt((const void *)SBBlueProgressAddonInstall,AddonPath) ||
        !ImageAt(dlsym(RTLD_DEFAULT,"LBXPresentationInstall"),PriorOverlayPath) ||
        !LBXVerifyCallerFile(ManagerPath,9490320,ManagerSHA) ||
        !LBXVerifyCallerFile(PriorOverlayPath,1145968,PriorOverlaySHA))return NO;
#endif
    // The full newer overlay already owns this hook; never stack another copy.
    if(dlsym(RTLD_DEFAULT,"SBSwitchProgressInstall"))return NO;
    return YES;
}

NSDictionary *SBBackendAppMetadata(void) {
#if SB_BLUE_PROGRESS_TESTING
    if(FixtureMetadata)return FixtureMetadata;
#endif
    return NSBundle.mainBundle.infoDictionary ?: @{};
}
BOOL SBBackendMetadataSupported(NSDictionary *metadata,NSString **reason) {
    NSDictionary *expected=@{@"CFBundleIdentifier":@"com.socialbox.app",
        @"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"};
    BOOL supported=CurrentProfile() && [metadata isKindOfClass:NSDictionary.class];
    for(NSString *key in expected)
        supported=supported && [metadata[key] isKindOfClass:NSString.class] && [metadata[key] isEqual:expected[key]];
    if(reason)*reason=supported?nil:@"Progress artwork profile unavailable";
    return supported;
}
SBScreen SBBackendScreen(id controller) {
    if(!SBBackendMetadataSupported(SBBackendAppMetadata(),NULL) ||
        ![controller isKindOfClass:UIViewController.class])return SBScreenUnknown;
    Class cls=object_getClass(controller);const char *image=class_getImageName(cls);
    if(!cls || ![NSStringFromClass(cls) isEqual:@"_Xc9m"] || !image ||
        ![@(image).stringByResolvingSymlinksInPath isEqual:NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath])
        return SBScreenUnknown;
    return SBScreenContainers;
}
UIColor *SBPanel(void) { return [UIColor colorWithRed:.092 green:.111 blue:.123 alpha:1]; }
BOOL SBBlueProgressAddonInstall(void) {
    if(!CurrentProfile())return NO;
    return SBSwitchProgressInstall();
}
#if !SB_BLUE_PROGRESS_TESTING
__attribute__((constructor)) static void InstallBlueProgressArtwork(void) {
    // Only the visual hook is attempted once after injected images load. No
    // loader preview, navigation, backend operation, startup mutation or retry.
    dispatch_async(dispatch_get_main_queue(),^{ SBBlueProgressAddonInstall(); });
}
#endif
