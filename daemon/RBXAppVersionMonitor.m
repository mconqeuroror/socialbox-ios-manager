#import "RBXAppRegistry.h"
#import "RBXAppVersionMonitor.h"

// D2 — version drift alert. Standalone plist at
// /var/mobile/Library/Preferences/com.redditbox.appversion.plist with keys:
//   latestKnownVersion : optional launcher-managed override
//   checkIntervalHours : recurrence (default 24)
//   alerts             : [{ type, message, timestamp }] (deduped by day, capped)
// Without an override, the installed/private source version is the safe baseline.

static NSString *const kVersionPlist = @"/var/mobile/Library/Preferences/com.redditbox.appversion.plist";
static NSString *const kCentralStore = @"/var/mobile/Library/Preferences/com.redditbox.store.json";
static NSString *const kDefaultLatestVersion = @"2025.30.0";
static const NSInteger kMaxAlerts = 20;

// Keeps the recurring timer alive for the daemon's lifetime (dispatch_main never
// returns, so this is never torn down).
static dispatch_source_t sTimer;

// "How many minors behind": Reddit versions look like 2025.30.0 — treat the
// first two components as one combined scale so a year rollover still counts as a
// gap. Returns latest - installed in combined units.
static NSInteger minorGap(NSString *installed, NSString *latest) {
    NSArray<NSString *> *pi = [installed componentsSeparatedByString:@"."];
    NSArray<NSString *> *pl = [latest componentsSeparatedByString:@"."];
    NSInteger xi = (pi.count > 0 ? [pi[0] integerValue] : 0) * 10000
                 + (pi.count > 1 ? [pi[1] integerValue] : 0);
    NSInteger xl = (pl.count > 0 ? [pl[0] integerValue] : 0) * 10000
                 + (pl.count > 1 ? [pl[1] integerValue] : 0);
    return xl - xi;
}

static NSString *dayStamp(NSDate *date) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt stringFromDate:date];
}

@implementation RBXAppVersionMonitor

+ (NSString *)installedRedditVersion {
    // Daemon runs as root: enumerate the bundle install area and read the first
    // Info.plist that belongs to com.reddit.Reddit. If anything is missing we
    // simply skip the check (fail-open).
    NSString *bundleRoot = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *appDirs = [fm contentsOfDirectoryAtPath:bundleRoot error:nil];
    for (NSString *dir in appDirs) {
        NSString *infoPath = [[[bundleRoot stringByAppendingPathComponent:dir]
                               stringByAppendingPathComponent:RBXRedditAppDescriptor()[@"sourceBundleName"]]
                              stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if ([info isKindOfClass:[NSDictionary class]] &&
            [info[@"CFBundleIdentifier"] isEqualToString:RBXRedditAppDescriptor()[@"sourceBundleIdentifier"]]) {
            NSString *v = info[@"CFBundleShortVersionString"];
            if ([v isKindOfClass:[NSString class]] && v.length) return v;
        }
    }
    return nil;
}

+ (NSString *)latestKnownVersion {
    // Standalone plist first, then the central store (op alias only — the
    // standalone file is authoritative and always created on first alert).
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kVersionPlist];
    if ([plist[@"latestKnownVersion"] isKindOfClass:[NSString class]] &&
        [(NSString *)plist[@"latestKnownVersion"] length]) {
        return plist[@"latestKnownVersion"];
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:kCentralStore]) {
        NSData *data = [NSData dataWithContentsOfFile:kCentralStore];
        NSDictionary *store = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([store isKindOfClass:[NSDictionary class]] &&
            [store[@"app"] isKindOfClass:[NSDictionary class]]) {
            id v = store[@"app"][@"latestKnownVersion"];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        }
    }
    NSDictionary *privateSource = [NSDictionary dictionaryWithContentsOfFile:
        [RBXRedditAppDescriptor()[@"sourceCachePath"] stringByAppendingPathComponent:@"Info.plist"]];
    NSString *sourceVersion = [privateSource[@"CFBundleShortVersionString"]
        isKindOfClass:[NSString class]] ? privateSource[@"CFBundleShortVersionString"] : nil;
    return sourceVersion.length ? sourceVersion :
        ([self installedRedditVersion] ?: kDefaultLatestVersion);
}

- (void)checkNow {
    NSString *installed = [[self class] installedRedditVersion];
    NSString *latest = [[self class] latestKnownVersion];
    if (!installed.length || !latest.length) {
        NSLog(@"redditboxd: app version check skipped (installed=%@ latest=%@)", installed, latest);
        return;
    }
    NSLog(@"redditboxd: Reddit app version installed=%@ latestKnown=%@", installed, latest);

    if (minorGap(installed, latest) > 2) {
        [self writeAlertWithMessage:[NSString stringWithFormat:
            @"Reddit app is outdated — update and re-verify containers (installed %@, latest %@)",
            installed, latest]];
    }
}

- (void)writeAlertWithMessage:(NSString *)message {
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:kVersionPlist];
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    if ([existing isKindOfClass:[NSDictionary class]]) [plist addEntriesFromDictionary:existing];
    // Keep the config keys present even on the first write.
    if (![plist[@"latestKnownVersion"] isKindOfClass:[NSString class]]) {
        plist[@"latestKnownVersion"] = kDefaultLatestVersion;
    }
    if (![plist[@"checkIntervalHours"] isKindOfClass:[NSNumber class]]) {
        plist[@"checkIntervalHours"] = @24;
    }

    NSMutableArray *alerts = [NSMutableArray array];
    if ([plist[@"alerts"] isKindOfClass:[NSArray class]]) {
        [alerts addObjectsFromArray:plist[@"alerts"]];
    }
    // Dedupe by calendar day so a persistent drift doesn't spam one entry per run.
    NSString *today = dayStamp([NSDate date]);
    for (NSDictionary *a in [alerts copy]) {
        if (![a isKindOfClass:[NSDictionary class]]) {
            [alerts removeObject:a];
        } else if ([a[@"day"] isKindOfClass:[NSString class]] && [a[@"day"] isEqualToString:today]) {
            return;   // already alerted today
        }
    }

    [alerts addObject:@{
        @"type": @"APP UPDATE",
        @"message": message,
        @"timestamp": [[NSDate date] description],
        @"day": today,
    }];
    if (alerts.count > kMaxAlerts) {
        [alerts removeObjectsInRange:NSMakeRange(0, alerts.count - kMaxAlerts)];
    }
    plist[@"alerts"] = alerts;
    [plist writeToFile:kVersionPlist atomically:YES];
    NSLog(@"redditboxd: alert written — %@", message);
}

- (void)startMonitoring {
    if (sTimer) {
        dispatch_source_cancel(sTimer);
        sTimer = nil;
    }
    [self checkNow];

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kVersionPlist];
    NSInteger hours = 24;
    if ([plist isKindOfClass:[NSDictionary class]] &&
        [plist[@"checkIntervalHours"] isKindOfClass:[NSNumber class]]) {
        hours = [(NSNumber *)plist[@"checkIntervalHours"] integerValue];
    }
    if (hours <= 0) hours = 24;

    // dispatch_source timer repeats after the first full interval; the immediate
    // checkNow above covers daemon start.
    sTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    uint64_t interval = (uint64_t)hours * 3600 * NSEC_PER_SEC;
    dispatch_source_set_timer(sTimer, dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, 60ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sTimer, ^{ [self checkNow]; });
    dispatch_resume(sTimer);
}

@end
