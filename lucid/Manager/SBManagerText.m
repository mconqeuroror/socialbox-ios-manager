#import "SBInterfaceCopy.h"

// Container manager plus the existing proxy and location pages. Identity
// and license screens stay out of this binary.
NSDictionary<NSString *, NSString *> *SBInterfaceTextCatalog(void) {
    static NSDictionary<NSString *, NSString *> *catalog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        catalog = @{
            @"brand.name" : @"SocialBox",
            @"brand.monogram" : @"S",
            @"common.close" : @"Close",
            @"common.unavailable" : @"Unavailable",
            @"common.functionUnavailable" : @"This feature is unavailable",
            @"common.actionUnavailable" : @"Action unavailable",
            @"common.incompatiblePrefix" : @"The core interface is incompatible. Code: ",
            @"nav.containers" : @"Containers",
            @"nav.proxy" : @"Proxy",
            @"nav.location" : @"Location",
            @"location.searchPlaceholder" : @"Place or coordinates",
            @"location.tools" : @"Location options",
            @"location.bookmarks" : @"Saved places",
            @"location.savePlace" : @"Save this place",
            @"location.history" : @"History",
            @"location.mapStyle" : @"Map type",
            @"location.useDevice" : @"Device location",
            @"location.copyCoordinates" : @"Copy coordinates",
            @"location.verify" : @"Verify reported location",
            @"location.start" : @"Start simulation",
            @"location.stop" : @"Stop simulation",
            @"location.pickHint" : @"Search a place, type lat, lon, or hold on the map.",
            @"location.ready" : @"Ready. Start simulation to use this place.",
            @"location.running" : @"GPS is set. Sites like what's my location still use your real IP, not this pin.",
            @"location.saved" : @"Place saved.",
            @"location.copied" : @"Coordinates copied.",
            @"location.emptyList" : @"Nothing saved yet.",
            @"location.dropped" : @"Dropped pin",
            @"location.devicePlace" : @"Device location",
            @"location.verified" : @"Reported %.5f, %.5f (%.0f m from the pin).",
            @"container.switch" : @"Switch",
            @"containers.create" : @"Create container",
            @"containers.loadFailed" : @"Could not load containers.",
            @"containers.tryAgain" : @"Please try again.",
            @"containers.empty" : @"No containers yet. Create one to start a new phone.",
            @"containers.rowSelected" : @"Selected",
            @"containers.selectedName" : @"Selected: %@",
            @"containers.swipeHint" : @"Swipe right to rename, left to delete.",
            @"container.rename" : @"Rename",
            @"container.delete" : @"Delete",
            @"proxies.detail" : @"Save a connection and assign it to a container. Untested connections are not marked as passed.",
            @"proxies.add" : @"Add proxy",
            @"proxies.emptyDetail" : @"Add a proxy, assign it to a container, then test the connection.",
            @"proxyImport.title" : @"Import connections",
            @"proxyImport.detail" : @"Paste connection details, review the preview, and confirm the import.",
        };
    });
    return catalog;
}

NSString *SBUIText(NSString *key) {
    if (![key isKindOfClass:NSString.class] || !key.length) return @"";
    return SBInterfaceTextCatalog()[key] ?: key;
}

BOOL SBUIHasText(NSString *key) {
    return key.length && SBInterfaceTextCatalog()[key] != nil;
}

NSString *SBUIContainerCount(NSUInteger shown, NSUInteger total) {
    return [NSString stringWithFormat:@"%lu of %lu containers", (unsigned long)shown, (unsigned long)total];
}

NSString *SBUIAppCount(NSUInteger count) {
    return [NSString stringWithFormat:@"%lu apps", (unsigned long)count];
}
