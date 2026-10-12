#pragma once
#import <Foundation/Foundation.h>

// Admission only. The observer never revokes an already-open lease. Retained
// findings survive disabling the sentinel; no UI acknowledgement clears them.
static inline NSString *RBXIsolationLaunchBlock(id document, NSString *container) {
    if (![document isKindOfClass:NSDictionary.class] ||
        ![document[@"containers"] isKindOfClass:NSDictionary.class] ||
        ![document[@"containers"][container] isKindOfClass:NSDictionary.class])
        return @"Container safety state is unavailable. Open Diagnostics; traffic stays closed.";
    NSDictionary *entry = document[@"containers"][container];
    if (entry[@"sentinelAlert"] && ![entry[@"sentinelAlert"] isEqual:@NO])
        return @"Isolation alert: opening is blocked. Inspect the finding in Diagnostics and repair the affected isolation before using this container.";
    id alerts = document[@"alerts"];
    if (alerts && ![alerts isKindOfClass:NSArray.class]) return @"Safety alerts are unreadable. Open Diagnostics; traffic stays closed.";
    for (id alert in alerts) {
        if (![alert isKindOfClass:NSDictionary.class]) return @"Safety alerts are unreadable. Open Diagnostics; traffic stays closed.";
        if ([alert[@"containerId"] isEqual:container] && [alert[@"type"] isEqual:@"ISOLATION SENTINEL"])
            return @"Isolation alert: opening is blocked. Disabling the sentinel does not clear an earlier finding. Open Diagnostics.";
    }
    return nil;
}
