#import "RBXCloneSupportDirectory.h"
#import "RBXStorageAccess.h"
#import "RBXStagedExecutable.h"
#import "RBXAppBundlePolicy.h"
#import "RBXInstallPaths.h"
#import "RBXCloneEpoch.h"
#import "RBXLiveness.h"
#import "RBXProfileTransport.h"
#import "RBXCloneManager.h"
#import "RBXAppRegistry.h"
#import "RBXAppKeychainPolicy.h"
#import "RBXAppLifecycle.h"
#import "RBXAppAdmission.h"
#import "RBXProcessController.h"
#import "RBXBoundedProcess.h"
#import "RBXOperationContext.h"
#import "RBXProfileIO.h"
#import <copyfile.h>
#import <dlfcn.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/file.h>
#import <string.h>
#import <unistd.h>
#import <archive.h>
#import <archive_entry.h>
#import <errno.h>
#import <stdio.h>
#import <time.h>
#import <math.h>
#import <signal.h>
#import <dirent.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString *const RBXCloneErrorDomain = @"com.redditbox.clone";
#define RBXSourceBundleID (RBXRedditAppDescriptor()[@"sourceBundleIdentifier"])
static NSString *const RBXTransactionsRoot =
    @"/var/mobile/Library/RedditBox/transactions";

static NSError *RBXCloneError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:RBXCloneErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"clone operation failed"}];
}

// Read-only probes may have no context. Mutating public entry points below
// require and capture one; every nested helper then sees that same TLS owner.
static BOOL RBXCloneContinue(NSError **error) {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    return !context || [context check:error];
}
static BOOL RBXCloneMayMutate(NSError **error) {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required");
        return NO;
    }
    return [context check:error];
}

// A lookup result without "proxy" means proven absence. nil means that the
// service could not provide a valid installed-app snapshot, never absence.
static NSDictionary *RBXInstalledApplication(NSString *identifier, NSError **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW))
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    });
    @try {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        SEL shared = NSSelectorFromString(@"defaultWorkspace");
        SEL installed = NSSelectorFromString(@"allInstalledApplications");
        id workspace = [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
        id apps = [workspace respondsToSelector:installed] ? ((id (*)(id, SEL))objc_msgSend)(workspace, installed) : nil;
        // A functioning iOS installation always contains system applications.
        if (![apps isKindOfClass:NSArray.class] || ![apps count]) {
            if (error) *error = RBXCloneError(70, @"LaunchServices installed-app enumeration is unavailable"); return nil;
        }
        id match = nil;
        SEL bundleID = NSSelectorFromString(@"bundleIdentifier");
        SEL bundleURL = NSSelectorFromString(@"bundleURL");
        for (id proxy in apps) {
            id candidate = [proxy respondsToSelector:bundleID] ? ((id (*)(id, SEL))objc_msgSend)(proxy, bundleID) : nil;
            id url = [proxy respondsToSelector:bundleURL] ? ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURL) : nil;
            if (![candidate isKindOfClass:NSString.class] || ![candidate length] ||
                ![url isKindOfClass:NSURL.class] || ![url isFileURL] || ![[url path] isAbsolutePath]) {
                if (error) *error = RBXCloneError(70, @"LaunchServices returned an invalid installed-app record"); return nil;
            }
            if (![candidate isEqualToString:identifier]) continue;
            if (match) { if (error) *error = RBXCloneError(70, @"LaunchServices returned duplicate app registrations"); return nil; }
            match = proxy;
        }
        return match ? @{@"workspace": workspace, @"proxy": match} : @{@"workspace": workspace};
    } @catch (NSException *exception) {
        if (error) *error = RBXCloneError(70, @"LaunchServices failed while enumerating installed apps"); return nil;
    }
}

static BOOL RBXRemovalIdentifierAllowed(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        [@[@"com.redditbox.launcher", @"com.redditbox.firewall", @"com.redditbox.firewall.PacketTunnel"] containsObject:identifier]) return NO;
    return RBXAppDescriptorForBundleIdentifier(identifier) != nil;
}

static NSString *RBXProxyPath(id proxy, NSString *property, NSError **error) {
    SEL selector = NSSelectorFromString(property);
    id value = [proxy respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(proxy, selector) : nil;
    if (![value isKindOfClass:NSURL.class] || ![value isFileURL] || ![[value path] isAbsolutePath]) {
        if (error) *error = RBXCloneError(71, [NSString stringWithFormat:@"registered app has no verifiable %@", property]); return nil;
    }
    return [[value path] stringByResolvingSymlinksInPath];
}

static BOOL RBXManagedRemovalPath(NSString *path, NSArray<NSString *> *roots, BOOL bundle, NSError **error) {
    BOOL location = NO;
    for (NSString *root in roots) {
        NSString *prefix = [root.stringByResolvingSymlinksInPath stringByAppendingString:@"/"];
        if (![path hasPrefix:prefix]) continue;
        NSArray *parts = [[path substringFromIndex:prefix.length] pathComponents];
        if (parts.count == (bundle ? 2 : 1) && [[NSUUID alloc] initWithUUIDString:parts[0]] &&
            (!bundle || [path.pathExtension.lowercaseString isEqualToString:@"app"])) location = YES;
    }
    struct stat info;
    if (!location || lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
        (bundle ? (info.st_uid != 0 && info.st_uid != 33 && info.st_uid != 501) : info.st_uid != 501)) {
        if (error) *error = RBXCloneError(71, @"uninstall target has an invalid container location, type, or owner"); return NO;
    }
    return YES;
}

static BOOL RBXValidateDataRemovalPath(NSString *path, NSString *identifier, BOOL plugin, NSError **error) {
    NSArray *roots = plugin ? @[@"/var/mobile/Containers/Data/PluginKitPlugin", @"/var/containers/Data/PluginKitPlugin"]
        : @[@"/var/mobile/Containers/Data/Application", @"/var/containers/Data/Application"];
    NSError *ownershipError=nil;
    if (!RBXManagedRemovalPath(path, roots, NO, &ownershipError)) {
        BOOL shape=NO;
        for(NSString *root in roots){NSString *prefix=[root.stringByResolvingSymlinksInPath stringByAppendingString:@"/"];
            if([path hasPrefix:prefix]){NSString *part=[path substringFromIndex:prefix.length];shape=shape||(![part containsString:@"/"]&&[[NSUUID alloc] initWithUUIDString:part]!=nil);}}
        if(plugin||!shape||![RBXStorageAccess ownsClosedHome:path bundleIdentifier:identifier error:error]){if(error&&!*error)*error=ownershipError;return NO;}
    }
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
        [path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    if (![identifier isEqual:metadata[@"MCMMetadataIdentifier"]]) {
        if (error) *error = RBXCloneError(71, @"uninstall data container does not belong to the registered app or plugin"); return NO;
    }
    return YES;
}

static NSDictionary *RBXCaptureRemoval(id proxy, NSString *identifier, NSString *expectedBundle, NSError **error) {
    @try {
        NSString *bundle = RBXProxyPath(proxy, @"bundleURL", error);
        if (!bundle || !RBXManagedRemovalPath(bundle, @[@"/var/containers/Bundle/Application",
            @"/var/mobile/Containers/Bundle/Application"], YES, error)) return nil;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
        if (![identifier isEqual:info[@"CFBundleIdentifier"]] ||
            (expectedBundle.length && ![bundle isEqualToString:expectedBundle.stringByResolvingSymlinksInPath])) {
            if (error) *error = RBXCloneError(71, @"registered uninstall target differs from the expected app bundle"); return nil;
        }
        NSString *installationTransaction = @"";
        NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(identifier);
        if (!descriptor) { if (error) *error = RBXCloneError(71, @"unregistered removal identity"); return nil; }
        if (![identifier isEqualToString:descriptor[@"sourceBundleIdentifier"]]) {
            NSDictionary *marker = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@".redditbox-clone.plist"]];
            NSString *container = [marker[@"containerId"] isKindOfClass:NSString.class] ? marker[@"containerId"] : nil;
            if (!container.length || ![identifier isEqualToString:RBXAppBundleIdentifier(descriptor, container)] ||
                ![identifier isEqual:marker[@"bundleIdentifier"]] || !RBXAppKeychainMarkerMatches(descriptor, identifier, marker)) {
                if (error) *error = RBXCloneError(71, @"uninstall target is not a verified RedditBox clone"); return nil;
            }
            installationTransaction = [marker[@"installationTransaction"] isKindOfClass:NSString.class]
                ? marker[@"installationTransaction"] : @"";
        }
        NSString *data = RBXProxyPath(proxy, @"dataContainerURL", error);
        if (!data || !RBXValidateDataRemovalPath(data, identifier, NO, error)) return nil;
        NSMutableArray *paths = [NSMutableArray arrayWithObjects:bundle, data, nil];
        SEL pluginsSelector = NSSelectorFromString(@"plugInKitPlugins");
        id plugins = [proxy respondsToSelector:pluginsSelector] ? ((id (*)(id, SEL))objc_msgSend)(proxy, pluginsSelector) : nil;
        if (![plugins isKindOfClass:NSArray.class]) {
            if (error) *error = RBXCloneError(71, @"cannot capture the app's registered plugin containers"); return nil;
        }
        NSMutableSet *pluginBundles = [NSMutableSet set];
        NSMutableArray *pluginIDs = [NSMutableArray array];
        NSString *pluginRoot = [bundle stringByAppendingPathComponent:@"PlugIns"];
        for (id plugin in plugins) {
            SEL idSelector = NSSelectorFromString(@"bundleIdentifier");
            id pluginID = [plugin respondsToSelector:idSelector] ? ((id (*)(id, SEL))objc_msgSend)(plugin, idSelector) : nil;
            NSString *pluginBundle = RBXProxyPath(plugin, @"bundleURL", error);
            NSString *pluginData = RBXProxyPath(plugin, @"dataContainerURL", error);
            NSDictionary *pluginInfo = pluginBundle ? [NSDictionary dictionaryWithContentsOfFile:
                [pluginBundle stringByAppendingPathComponent:@"Info.plist"]] : nil;
            if (![pluginID isKindOfClass:NSString.class] ||
                ![pluginID hasPrefix:[identifier stringByAppendingString:@"."]] ||
                ![pluginID isEqual:pluginInfo[@"CFBundleIdentifier"]] ||
                ![pluginBundle.stringByDeletingLastPathComponent isEqualToString:pluginRoot] ||
                ![pluginBundle.pathExtension.lowercaseString isEqualToString:@"appex"] ||
                [pluginIDs containsObject:pluginID] || !pluginData ||
                !RBXValidateDataRemovalPath(pluginData, pluginID, YES, error)) {
                if (error && !*error) *error = RBXCloneError(71, @"registered plugin is not an owned embedded app extension"); return nil;
            }
            struct stat pluginStat;
            if (lstat(pluginBundle.fileSystemRepresentation, &pluginStat) != 0 || !S_ISDIR(pluginStat.st_mode) ||
                (pluginStat.st_uid != 0 && pluginStat.st_uid != 33 && pluginStat.st_uid != 501)) {
                if (error) *error = RBXCloneError(71, @"embedded plugin path cannot be verified"); return nil;
            }
            [pluginBundles addObject:pluginBundle]; [pluginIDs addObject:pluginID];
            [paths addObject:pluginBundle]; [paths addObject:pluginData];
        }
        NSError *listingError = nil;
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:pluginRoot error:&listingError];
        if (!entries) {
            // lstat distinguishes proven absence from permission and I/O failures.
            struct stat unused;
            if (lstat(pluginRoot.fileSystemRepresentation, &unused) == 0 || errno != ENOENT) {
                if (error) *error = listingError ?: RBXCloneError(71, @"cannot enumerate embedded plugins"); return nil;
            }
        }
        for (NSString *entry in entries) {
            if ([entry.pathExtension.lowercaseString isEqualToString:@"appex"] &&
                ![pluginBundles containsObject:[pluginRoot stringByAppendingPathComponent:entry]]) {
                if (error) *error = RBXCloneError(71, @"an embedded plugin has no verifiable registered data container"); return nil;
            }
        }
        struct stat bundleStat, dataStat;
        if (lstat(bundle.fileSystemRepresentation, &bundleStat) != 0 || lstat(data.fileSystemRepresentation, &dataStat) != 0) {
            if (error) *error = RBXCloneError(71, @"uninstall target changed while capturing its identity"); return nil;
        }
        return @{@"bundlePath": bundle, @"dataPath": data, @"paths": paths, @"pluginIDs": pluginIDs,
            @"bundleDevice": @(bundleStat.st_dev), @"bundleInode": @(bundleStat.st_ino),
            @"dataDevice": @(dataStat.st_dev), @"dataInode": @(dataStat.st_ino),
            @"installationTransaction": installationTransaction};
    } @catch (NSException *exception) {
        if (error) *error = RBXCloneError(71, @"LaunchServices failed while capturing uninstall targets"); return nil;
    }
}

static BOOL RBXNoPendingRemoval(NSString *identifier, NSError **error) {
    NSString *path = [[[RBXTransactionsRoot stringByAppendingPathComponent:@"uninstall-evidence"]
        stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:@"transaction.plist"];
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) < 0 && errno == ENOENT) return YES;
    if (error) *error = RBXCloneError(73, @"pending or unreadable uninstall evidence must be resolved before installing this clone");
    return NO;
}

static BOOL RBXNoPendingInstallation(NSString *identifier, NSError **error) {
    NSError *listingError = nil;
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:RBXTransactionsRoot error:&listingError];
    if (!entries) {
        struct stat info;
        if (lstat(RBXTransactionsRoot.fileSystemRepresentation, &info) < 0 && errno == ENOENT) return YES;
        if (error) *error = listingError ?: RBXCloneError(73, @"cannot inspect clone recovery journals before removal"); return NO;
    }
    for (NSString *entry in entries) {
        if ([entry isEqualToString:@"uninstall-evidence"] || [entry isEqualToString:@".lock"]) continue;
        NSString *path = [[RBXTransactionsRoot stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"transaction.plist"];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) < 0 && errno == ENOENT) continue;
        NSDictionary *journal = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![journal[@"bundleIdentifier"] isKindOfClass:NSString.class]) {
            if (error) *error = RBXCloneError(73, @"an unreadable clone journal prevents safe removal; recover transactions first"); return NO;
        }
        if (![identifier isEqual:journal[@"bundleIdentifier"]]) continue;
        if (RBXAppInstallationRecordDescriptor(journal) &&
            ([@"committed" isEqual:journal[@"state"]] || [@"complete" isEqual:journal[@"recoveryState"]])) continue;
        if (error) *error = RBXCloneError(73, @"this clone has an unfinished installation journal; recover that transaction before deleting it"); return NO;
    }
    return YES;
}

static BOOL RBXRemovalPathsAbsent(NSArray<NSString *> *paths, BOOL *absent, NSError **error) {
    *absent = YES;
    for (NSString *path in paths) {
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) == 0) { *absent = NO; continue; }
        if (errno != ENOENT) {
            if (error) *error = RBXCloneError(72, @"cannot verify disappearance of an uninstall target"); return NO;
        }
    }
    return YES;
}

static BOOL RBXWriteJournal(NSString *root, NSMutableDictionary *journal,
                            NSString *phase, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    NSMutableDictionary *next = [journal mutableCopy];
    next[@"state"] = phase;
    NSString *path = [root stringByAppendingPathComponent:@"transaction.plist"];
    BOOL ok = [next writeToFile:path atomically:YES] &&
        [[NSDictionary dictionaryWithContentsOfFile:path] isEqualToDictionary:next];
    int fd = ok ? open(path.fileSystemRepresentation, O_RDONLY) : -1;
    ok = fd >= 0 && fsync(fd) == 0;
    if (fd >= 0) close(fd);
    int directory = ok ? open(root.fileSystemRepresentation, O_RDONLY) : -1;
    ok = directory >= 0 && fsync(directory) == 0;
    if (directory >= 0) close(directory);
    if (!ok) {
        if (error) *error = RBXCloneError(32, @"cannot durably persist clone transaction phase");
        return NO;
    }
    [journal setDictionary:next];
    return YES;
}

static int RBXLockTransactions(NSError **error) {
    if (!RBXCloneMayMutate(error)) return -1;
    if (![NSFileManager.defaultManager createDirectoryAtPath:RBXTransactionsRoot
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error]) return -1;
    NSString *path = [RBXTransactionsRoot stringByAppendingPathComponent:@".lock"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (fd >= 0) close(fd);
        if (error) *error = RBXCloneError(40, @"another clone transaction or recovery is running");
        return -1;
    }
    return fd;
}

static int RBXCopyProgress(int what, int stage, copyfile_state_t state,
    const char *source, const char *destination, void *opaque) {
    RBXOperationContext *context = (__bridge RBXOperationContext *)opaque;
    return [context check:nil] ? COPYFILE_CONTINUE : COPYFILE_QUIT;
}

static BOOL RBXSpawnAndWait(NSString *executable, NSArray<NSString *> *arguments, NSError **error) {
    return [RBXBoundedProcess runExecutable:executable arguments:arguments
        context:RBXOperationContext.currentContext outputPath:nil maximumOutputBytes:0 error:error];
}

// Private evidence for this installer invocation only.
static uid_t RBXInstallerEvidenceOwner(void) {
#ifdef RBX_INSTALL_EVIDENCE_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static BOOL RBXInstallerOwnedFile(int fd, BOOL directory, BOOL privateFile) {
    struct stat info;
    return fd >= 0 && fstat(fd, &info) == 0 && info.st_uid == RBXInstallerEvidenceOwner() &&
        !(info.st_mode & ((directory || privateFile) ? 0077 : 0022)) &&
        (directory ? S_ISDIR(info.st_mode) : (S_ISREG(info.st_mode) && info.st_nlink == 1));
}
static int RBXOpenInstallerEvidence(NSString *ipa, NSDictionary *descriptor, NSError **error) {
    BOOL shape = [ipa isKindOfClass:NSString.class] && ipa.isAbsolutePath &&
        [ipa isEqual:ipa.stringByStandardizingPath] &&
        [@[@"clone.ipa", @"previous.ipa"] containsObject:ipa.lastPathComponent];
    NSString *parent = shape ? ipa.stringByDeletingLastPathComponent : nil;
    shape = shape && [parent.stringByDeletingLastPathComponent isEqual:RBXTransactionsRoot] &&
        [[NSUUID alloc] initWithUUIDString:parent.lastPathComponent] != nil;
    int root = shape ? open(RBXTransactionsRoot.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
    int directory = RBXInstallerOwnedFile(root, YES, YES)
        ? openat(root, parent.lastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
    if (root >= 0) close(root);
    BOOL safe = RBXInstallerOwnedFile(directory, YES, YES);
    int archive = safe ? openat(directory, ipa.lastPathComponent.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) : -1;
    int journal = safe ? openat(directory, "transaction.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) : -1;
    struct stat archiveInfo, journalInfo;
    safe = safe && RBXInstallerOwnedFile(archive, NO, NO) && fstat(archive, &archiveInfo) == 0 && archiveInfo.st_size > 0 &&
        RBXInstallerOwnedFile(journal, NO, NO) && fstat(journal, &journalInfo) == 0 && journalInfo.st_size > 0 && journalInfo.st_size <= 65536;
    NSMutableData *bytes = [NSMutableData data];
    while (safe) {
        unsigned char buffer[4096];
        ssize_t count = read(journal, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { safe = NO; break; }
        if (!count) break;
        [bytes appendBytes:buffer length:(NSUInteger)count];
        if (bytes.length > 65536) safe = NO;
    }
    id record = safe ? [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil] : nil;
    safe = safe && RBXAppInstallationRecordOwnedBy(record, descriptor) &&
        [@[@"install-attempted", @"installed"] containsObject:record[@"state"] ?: @""];
    if (archive >= 0) close(archive);
    if (journal >= 0) close(journal);
    if (safe) return directory;
    if (directory >= 0) close(directory);
    if (error) *error = RBXCloneError(92, @"Installer requires a verified private clone transaction and IPA");
    return -1;
}
static BOOL RBXInstallerNumericStatus(id value, NSInteger minimum, NSInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && floor(number) == number && number >= minimum && number <= maximum;
}
static void RBXFinishInstallerEvidence(int directory, NSString *name, NSError *failure, BOOL success) {
    NSString *output = [name stringByAppendingPathExtension:@"stdout"];
    int captured = openat(directory, output.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    BOOL captureOwned = RBXInstallerOwnedFile(captured, NO, YES);
    if (success) {
        if (captureOwned) unlinkat(directory, output.fileSystemRepresentation, 0);
        if (captured >= 0) close(captured);
        return;
    }
    if (captureOwned) fsync(captured);
    if (captured >= 0) close(captured);
    NSMutableDictionary *receipt = [@{@"formatVersion":@1} mutableCopy];
    for (NSString *key in @[@"childStarted", @"childQuiescent"]) {
        id value = failure.userInfo[key];
        if ([@YES isEqual:value] || [@NO isEqual:value]) receipt[key] = @([value boolValue]);
    }
    if ([@YES isEqual:receipt[@"childStarted"]] && [@YES isEqual:receipt[@"childQuiescent"]]) {
        id exitCode = failure.userInfo[@"exitCode"], signal = failure.userInfo[@"terminationSignal"];
        if (!signal && RBXInstallerNumericStatus(exitCode, 0, 255)) receipt[@"exitCode"] = exitCode;
        else if (!exitCode && RBXInstallerNumericStatus(signal, 1, NSIG - 1)) receipt[@"terminationSignal"] = signal;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:receipt format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *receiptName = [name stringByAppendingPathExtension:@"plist"];
    int fd = data.length ? openat(directory, receiptName.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600) : -1;
    BOOL written = fd >= 0 && RBXInstallerOwnedFile(fd, NO, YES);
    NSUInteger offset = 0;
    while (written && offset < data.length) {
        ssize_t count = write(fd, (const unsigned char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { written = NO; break; }
        offset += (NSUInteger)count;
    }
    if (written) written = fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) written = NO;
    if (written) written = fsync(directory) == 0;
    if (!written) NSLog(@"redditboxd: private installer evidence could not be durably saved");
}
// End installer evidence helpers.

static NSString *RBXExecutable(NSString *name) {
    NSArray<NSString *> *candidates = @[
        RBXInstalledPath([@"/usr/bin" stringByAppendingPathComponent:name]),
        [@"/usr/bin" stringByAppendingPathComponent:name],
        RBXInstalledPath([@"/bin" stringByAppendingPathComponent:name]),
        [@"/bin" stringByAppendingPathComponent:name],
    ];
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

static BOOL RBXDeletionContainerID(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) return NO;
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-_"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSDictionary *RBXReadOwnedPlist(NSString *path, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        if (errno != ENOENT && error) *error = RBXCloneError(80, @"cannot read owned deletion evidence"); return nil;
    }
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == 0 &&
        !(info.st_mode & 0022) && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= 2 * 1024 * 1024;
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[8192];
    while (valid) {
        if (!RBXCloneContinue(error)) { valid = NO; break; }
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) break;
        [data appendBytes:buffer length:(NSUInteger)count];
        if (data.length > 2 * 1024 * 1024) valid = NO;
    }
    close(fd);
    id value = valid ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXCloneError(80, @"owned deletion evidence is corrupt or unsafe"); return nil;
    }
    return value;
}

static BOOL RBXContainerAvailable(NSString *container, NSError **error) {
    if (!RBXDeletionContainerID(container)) {
        if (error) *error = RBXCloneError(80, @"invalid clone container identifier"); return NO;
    }
    NSString *deletionRoot = @"/var/mobile/Library/RedditBox/deletions";
    struct stat info;
    int directoryStatus = lstat(deletionRoot.fileSystemRepresentation, &info);
    if (directoryStatus == 0) {
        if (!S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0077)) {
            if (error) *error = RBXCloneError(80, @"deletion reservation directory is unsafe"); return NO;
        }
        NSString *journal = [[deletionRoot stringByAppendingPathComponent:container] stringByAppendingPathExtension:@"plist"];
        if (lstat(journal.fileSystemRepresentation, &info) == 0 || errno != ENOENT) {
            if (error) *error = RBXCloneError(80, @"container is reserved by deletion evidence and cannot be restored or reused"); return NO;
        }
    } else if (errno != ENOENT) {
        if (error) *error = RBXCloneError(80, @"deletion reservations cannot be inspected"); return NO;
    }
    NSString *retiredPath = @"/var/mobile/Library/Preferences/com.redditbox.deleted-containers.plist";
    int retiredStatus = lstat(retiredPath.fileSystemRepresentation, &info);
    if (retiredStatus < 0 && errno == ENOENT) return YES;
    if (retiredStatus != 0 || !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_nlink != 1 || (info.st_mode & 0022)) {
        if (error) *error = RBXCloneError(80, @"retired container reservation file is unsafe"); return NO;
    }
    NSArray *retired = [NSArray arrayWithContentsOfFile:retiredPath];
    if (!retired) {
        if (error) *error = RBXCloneError(80, @"retired container reservations cannot be verified"); return NO;
    }
    for (id value in retired) {
        if (!RBXDeletionContainerID(value)) {
            if (error) *error = RBXCloneError(80, @"retired container reservation data is invalid"); return NO;
        }
    }
    if ([retired containsObject:container]) {
        if (error) *error = RBXCloneError(80, @"container is permanently retired"); return NO;
    }
    return YES;
}

static BOOL RBXDeletionClosed(NSString *container, NSError **error) {
    NSDictionary *lease = RBXReadOwnedPlist(@"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist", error);
    NSString *binding = [[NSString stringWithContentsOfFile:@"/var/mobile/Library/Preferences/com.redditbox.activeContainer"
        encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![@"closed" isEqual:lease[@"state"]] || !binding.length || [binding isEqualToString:container]) {
        if (error && !*error) *error = RBXCloneError(80, @"deletion requires CLOSED traffic and an inactive target"); return NO;
    }
    return YES;
}

static BOOL RBXDeletionTargetValid(NSDictionary *target, NSError **error) {
    NSDictionary *descriptor = RBXAppDeletionTargetDescriptor(target);
    if (!descriptor ||
        ![target[@"transactions"] isKindOfClass:NSArray.class] ||
        (target[@"bundlePath"] && (![target[@"bundlePath"] isKindOfClass:NSString.class] || ![target[@"bundlePath"] isAbsolutePath]))) {
        if (error) *error = RBXCloneError(80, @"saved deletion target does not match its exact clone identity"); return NO;
    }
    for (id record in target[@"transactions"]) {
        if (![record isKindOfClass:NSDictionary.class] || ![record[@"root"] isKindOfClass:NSString.class] ||
            ![record[@"device"] isKindOfClass:NSNumber.class] || ![record[@"inode"] isKindOfClass:NSNumber.class] ||
            ![record[@"journal"] isKindOfClass:NSDictionary.class]) {
            if (error) *error = RBXCloneError(80, @"saved deletion backup metadata is invalid"); return NO;
        }
        NSDictionary *journal = record[@"journal"];
        NSString *root = record[@"root"];
        if (![root.stringByDeletingLastPathComponent isEqualToString:RBXTransactionsRoot] ||
            ![[NSUUID alloc] initWithUUIDString:root.lastPathComponent] ||
            ![target[@"containerId"] isEqual:journal[@"containerId"]] || ![target[@"bundleIdentifier"] isEqual:journal[@"bundleIdentifier"]] ||
            !RBXAppInstallationRecordOwnedBy(journal, descriptor) ||
            !([@"committed" isEqual:journal[@"state"]] || [@"complete" isEqual:journal[@"recoveryState"]])) {
            if (error) *error = RBXCloneError(80, @"saved deletion backup is unfinished or belongs to another clone"); return NO;
        }
    }
    id installation = target[@"installation"];
    if (installation) {
        if (![installation isKindOfClass:NSDictionary.class] || ![installation[@"paths"] isKindOfClass:NSArray.class] ||
            [installation[@"paths"] count] < 2 || ![installation[@"pluginIDs"] isKindOfClass:NSArray.class]) {
            if (error) *error = RBXCloneError(80, @"saved deletion installation capture is invalid"); return NO;
        }
        for (NSString *key in @[@"bundlePath", @"dataPath", @"installationTransaction"]) {
            if (![installation[key] isKindOfClass:NSString.class]) { if (error) *error = RBXCloneError(80, @"saved deletion capture has an invalid identity"); return NO; }
        }
        for (NSString *key in @[@"bundleDevice", @"bundleInode", @"dataDevice", @"dataInode"]) {
            if (![installation[key] isKindOfClass:NSNumber.class]) { if (error) *error = RBXCloneError(80, @"saved deletion capture has invalid filesystem identity"); return NO; }
        }
        for (id path in installation[@"paths"]) {
            if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) { if (error) *error = RBXCloneError(80, @"saved deletion capture contains an invalid path"); return NO; }
        }
        for (id identifier in installation[@"pluginIDs"]) {
            if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:[target[@"bundleIdentifier"] stringByAppendingString:@"."]]) {
                if (error) *error = RBXCloneError(80, @"saved deletion capture contains an unrelated plugin"); return NO;
            }
        }
    }
    for (NSString *key in @[@"ipa", @"sharedExport"]) {
        id record = target[key];
        if (record && (![record isKindOfClass:NSDictionary.class] || ![record[@"path"] isKindOfClass:NSString.class] ||
            ![record[@"device"] isKindOfClass:NSNumber.class] || ![record[@"inode"] isKindOfClass:NSNumber.class])) {
            if (error) *error = RBXCloneError(80, @"saved deletion export metadata is invalid"); return NO;
        }
    }
    return YES;
}

static BOOL RBXDeletionPhase(NSDictionary *target, NSDictionary *descriptor, NSString *phase, NSError **error) {
    if (!RBXDeletionTargetValid(target, error) || ![RBXAppDeletionTargetDescriptor(target) isEqual:descriptor]) {
        if (error && !*error) *error = RBXCloneError(80, @"deletion target belongs to another app"); return NO;
    }
    if (!RBXDeletionClosed(target[@"containerId"], error)) return NO;
    NSString *path = [[@"/var/mobile/Library/RedditBox/deletions" stringByAppendingPathComponent:target[@"containerId"]]
        stringByAppendingPathExtension:@"plist"];
    NSDictionary *journal = RBXReadOwnedPlist(path, error);
    if (![RBXAppDeletionJournalDescriptor(journal) isEqual:descriptor] || ![target[@"containerId"] isEqual:journal[@"containerId"]] ||
        ![phase isEqual:journal[@"phase"]] || ![target isEqual:journal[@"target"]]) {
        if (error && !*error) *error = RBXCloneError(80, @"deletion phase has no matching durable target journal"); return NO;
    }
    return YES;
}

static NSArray *RBXDeletionTransactions(NSString *container, NSString *bundle, NSError **error) {
    NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(bundle);
    if (!RBXDeletionContainerID(container) || ![RBXAppBundleIdentifier(descriptor, container) isEqual:bundle]) {
        if (error) *error = RBXCloneError(82, @"deletion backup query has an invalid app identity"); return nil;
    }
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:RBXTransactionsRoot error:error];
    if (!entries) return nil;
    NSMutableArray *records = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (![[NSUUID alloc] initWithUUIDString:entry]) continue;
        NSString *root = [RBXTransactionsRoot stringByAppendingPathComponent:entry];
        struct stat rootInfo;
        if (lstat(root.fileSystemRepresentation, &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode) ||
            rootInfo.st_uid != 0 || (rootInfo.st_mode & 0077)) {
            if (error) *error = RBXCloneError(82, @"transaction root is unreadable or unowned"); return nil;
        }
        NSError *readError = nil;
        NSDictionary *journal = RBXReadOwnedPlist([root stringByAppendingPathComponent:@"transaction.plist"], &readError);
        if (readError) { if (error) *error = readError; return nil; }
        if (!journal) {
            NSString *markerPath = [descriptor[@"sourceBundleName"] stringByAppendingPathComponent:descriptor[@"cloneMarkerName"]];
            for (NSString *relative in @[[@"Payload" stringByAppendingPathComponent:markerPath],
                [@"backup/Payload" stringByAppendingPathComponent:markerPath]]) {
                NSDictionary *marker = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:relative]];
                if ([bundle isEqual:marker[@"bundleIdentifier"]]) {
                    if (error) *error = RBXCloneError(82, @"an unjournaled clone backup requires manual recovery before deletion"); return nil;
                }
            }
            continue;
        }
        if (!RBXAppInstallationRecordDescriptor(journal)) {
            if (error) *error = RBXCloneError(82, @"clone backup journal ownership is corrupt"); return nil;
        }
        if (![bundle isEqual:journal[@"bundleIdentifier"]] && ![container isEqual:journal[@"containerId"]]) continue;
        struct stat info;
        if (![bundle isEqual:journal[@"bundleIdentifier"]] || ![container isEqual:journal[@"containerId"]] ||
            !RBXAppInstallationRecordOwnedBy(journal, descriptor) ||
            !([@"committed" isEqual:journal[@"state"]] || [@"complete" isEqual:journal[@"recoveryState"]]) ||
            lstat(root.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0077)) {
            if (error) *error = RBXCloneError(82, @"unfinished or unowned clone backup must be recovered before deletion"); return nil;
        }
        [records addObject:@{@"root": root, @"device": @(info.st_dev), @"inode": @(info.st_ino), @"journal": journal}];
    }
    return records;
}

// Relative unlinkat traversal never follows a symlink from an owned artifact
// into another container. Already-removed descendants are retryable success.
static BOOL RBXRemoveArtifactAt(int parent, const char *name, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) < 0) {
        if (errno == ENOENT) return YES;
        if (error) *error = RBXCloneError(83, @"cannot inspect owned deletion artifact"); return NO;
    }
    if (!S_ISDIR(info.st_mode)) {
        if (unlinkat(parent, name, 0) == 0 || errno == ENOENT) return YES;
        if (error) *error = RBXCloneError(83, @"cannot remove owned deletion artifact"); return NO;
    }
    int child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (child < 0) { if (error) *error = RBXCloneError(83, @"owned artifact directory changed during deletion"); return NO; }
    struct stat opened;
    if (fstat(child, &opened) != 0 || opened.st_dev != info.st_dev || opened.st_ino != info.st_ino) {
        close(child); if (error) *error = RBXCloneError(83, @"owned artifact identity changed during deletion"); return NO;
    }
    DIR *entries = fdopendir(dup(child));
    if (!entries) { close(child); if (error) *error = RBXCloneError(83, @"cannot enumerate owned artifact directory"); return NO; }
    BOOL ok = YES;
    for (;;) {
        if (!RBXCloneMayMutate(error)) { ok = NO; break; }
        errno = 0;
        struct dirent *entry = readdir(entries);
        if (!entry) { if (errno) ok = NO; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (!RBXRemoveArtifactAt(child, entry->d_name, error)) { ok = NO; break; }
    }
    closedir(entries); close(child);
    if (ok) ok = unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT;
    if (!ok && error && !*error) *error = RBXCloneError(83, @"owned artifact cleanup did not finish");
    return ok;
}

static BOOL RBXSyncArtifactParent(NSString *path, NSError **error) {
    NSString *parent = path.stringByDeletingLastPathComponent;
    while (parent.length) {
        int directory = open(parent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (directory >= 0) {
            BOOL ok = fsync(directory) == 0; close(directory);
            if (!ok && error) *error = RBXCloneError(83, @"cannot persist artifact namespace state");
            return ok;
        }
        if (errno != ENOENT || [parent isEqualToString:@"/"]) break;
        parent = parent.stringByDeletingLastPathComponent;
    }
    if (error) *error = RBXCloneError(83, @"cannot sync artifact parent"); return NO;
}

static BOOL RBXRemoveArtifactPath(NSString *path, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    int parent = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (parent < 0) {
        if (errno == ENOENT) {
            NSString *ancestor = path.stringByDeletingLastPathComponent;
            while (ancestor.length > 1) {
                ancestor = ancestor.stringByDeletingLastPathComponent;
                int directory = open(ancestor.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
                if (directory >= 0) {
                    BOOL durable = fsync(directory) == 0; close(directory);
                    if (!durable && error) *error = RBXCloneError(83, @"cannot persist artifact absence");
                    return durable;
                }
                if (errno != ENOENT) break;
            }
        }
        if (error) *error = RBXCloneError(83, @"cannot open owned artifact parent"); return NO;
    }
    BOOL ok = RBXRemoveArtifactAt(parent, path.lastPathComponent.fileSystemRepresentation, error) && fsync(parent) == 0;
    close(parent);
    if (!ok && error && !*error) *error = RBXCloneError(83, @"cannot persist owned artifact cleanup");
    return ok;
}

// Used only by explicit deletion's signer, entitlement inspector, and cleaner.
// The root-owned stdout descriptor is opened before the cleaner drops to mobile.
static BOOL RBXRunDeletionTool(NSString *tool, NSArray<NSString *> *arguments,
    NSString *output, NSUInteger maxBytes, NSError **error) {
    struct stat toolStat;
    if (!tool.length || lstat(tool.fileSystemRepresentation, &toolStat) != 0 || !S_ISREG(toolStat.st_mode) ||
        toolStat.st_uid != 0 || (toolStat.st_mode & 0022) || ![NSFileManager.defaultManager isExecutableFileAtPath:tool]) {
        if (error) *error = RBXCloneError(81, @"a trusted deletion helper or signer is unavailable"); return NO;
    }
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *fencePath = [output.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"helper-exit-unproven"];
    int fence = open(fencePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int directory = open(output.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    const char fenceText[] = "Helper exit must be proven before this job can be retried or removed.\n";
    BOOL fenced = fence >= 0 && write(fence, fenceText, sizeof(fenceText) - 1) == sizeof(fenceText) - 1 &&
        fsync(fence) == 0 && directory >= 0 && fsync(directory) == 0;
    if (fence >= 0) close(fence);
    if (!fenced) {
        if (directory >= 0) close(directory);
        if (error) *error = RBXCloneError(81, @"cannot durably reserve helper execution; retained job requires review"); return NO;
    }
    NSError *runError = nil;
    BOOL success = [RBXBoundedProcess runExecutable:tool arguments:arguments
        context:RBXOperationContext.currentContext maximumDuration:15.0
        outputPath:output maximumOutputBytes:maxBytes error:&runError];
    BOOL stopped = success || [runError.userInfo[@"childQuiescent"] boolValue];
    BOOL cleared = stopped && unlink(fencePath.fileSystemRepresentation) == 0 && fsync(directory) == 0;
    close(directory);
    if (!success || !cleared) {
        if (error) *error = runError ?: RBXCloneError(81, @"helper exit reservation could not be cleared durably");
        return NO;
    }
    return YES;
}

struct RBXBoundedExportReader { int fd; off_t remaining; uint8_t bytes[65536]; };
static la_ssize_t RBXReadExportBytes(struct archive *archive, void *context, const void **bytes) {
    struct RBXBoundedExportReader *reader = context;
    *bytes = reader->bytes;
    if (!RBXCloneContinue(nil)) { archive_set_error(archive, ECANCELED, "operation cancelled"); return -1; }
    if (reader->remaining <= 0) return 0;
    size_t wanted = (size_t)MIN((off_t)sizeof(reader->bytes), reader->remaining);
    ssize_t count;
    do { count = read(reader->fd, reader->bytes, wanted); } while (count < 0 && errno == EINTR);
    if (count < 0) { archive_set_error(archive, errno, "export read failed"); return -1; }
    reader->remaining -= count;
    return count;
}

// Read only the small clone marker; no untrusted archive path is
// extracted. The digest binds both singleton and per-clone exports to this
// preparation even though mobile can access the exported file.
static NSDictionary *RBXExportIdentity(NSString *path, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        if (errno != ENOENT && error) *error = RBXCloneError(84, @"cannot read exported IPA ownership"); return nil;
    }
    struct stat before, after;
    BOOL valid = fstat(fd, &before) == 0 && S_ISREG(before.st_mode) && before.st_nlink == 1 &&
        (before.st_uid == 0 || before.st_uid == 501) && before.st_size > 0 && before.st_size <= 4LL * 1024 * 1024 * 1024;
    struct archive *archive = valid ? archive_read_new() : NULL;
    NSDictionary *marker = nil;
    if (archive) {
        archive_read_support_filter_none(archive); archive_read_support_format_zip(archive);
        struct RBXBoundedExportReader reader = {.fd = fd, .remaining = before.st_size};
        valid = archive_read_open(archive, &reader, NULL, RBXReadExportBytes, NULL) == ARCHIVE_OK;
        struct archive_entry *entry = NULL;
        unsigned count = 0;
        int status = ARCHIVE_EOF;
        while (valid && (status = archive_read_next_header(archive, &entry)) == ARCHIVE_OK) {
            if (!RBXCloneContinue(error)) { valid = NO; break; }
            if (++count > 200000) { valid = NO; break; }
            const char *name = archive_entry_pathname_utf8(entry);
            NSString *relative = name ? [NSString stringWithUTF8String:name] : nil;
            NSArray *parts = relative.pathComponents;
            if (parts.count == 3 && [parts[0] isEqualToString:@"Payload"] &&
                [[parts[1] pathExtension] isEqualToString:@"app"] && [parts[2] isEqualToString:@".redditbox-clone.plist"]) {
                la_int64_t size = archive_entry_size(entry);
                if (marker || archive_entry_filetype(entry) != AE_IFREG || archive_entry_symlink(entry) ||
                    archive_entry_hardlink(entry) || size > 65536) { valid = NO; break; }
                // Streaming ZIP writers put the actual size in a trailing data
                // descriptor. A zero local-header size is not an empty marker.
                // Bound the decoded bytes themselves, including unknown sizes.
                NSMutableData *bytes = [NSMutableData data];
                while (valid) {
                    if (!RBXCloneContinue(error)) { valid = NO; break; }
                    uint8_t decoded[4096];
                    la_ssize_t readBytes = archive_read_data(archive, decoded, MIN(sizeof(decoded), 65537 - bytes.length));
                    if (readBytes < 0) { valid = NO; break; }
                    if (!readBytes) break;
                    [bytes appendBytes:decoded length:(NSUInteger)readBytes];
                    if (bytes.length > 65536) valid = NO;
                }
                valid = valid && bytes.length > 0 && (size <= 0 || bytes.length == (NSUInteger)size);
                id value = valid ? [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil] : nil;
                if (![value isKindOfClass:NSDictionary.class]) { valid = NO; break; }
                marker = value;
            }
            if (archive_read_data_skip(archive) != ARCHIVE_OK) { valid = NO; break; }
        }
        valid = valid && status == ARCHIVE_EOF;
        archive_read_free(archive);
    } else valid = NO;
    NSString *container = marker[@"containerId"], *bundle = marker[@"bundleIdentifier"];
    NSDictionary *descriptor = RBXAppDescriptorForType(marker[@"appType"]);
    valid = valid && RBXDeletionContainerID(container) &&
        [RBXAppBundleIdentifier(descriptor, container) isEqual:bundle] &&
        [RBXAppKeychainGroup(descriptor, bundle) isEqual:marker[@"keychainAccessGroup"]] &&
        RBXAppKeychainMarkerMatches(descriptor, bundle, marker);
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    if (valid && lseek(fd, 0, SEEK_SET) < 0) valid = NO;
    uint8_t buffer[65536];
    off_t total = 0;
    while (valid && total < before.st_size) {
        if (!RBXCloneContinue(error)) { valid = NO; break; }
        size_t wanted = (size_t)MIN((off_t)sizeof(buffer), before.st_size - total);
        ssize_t count = read(fd, buffer, wanted);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) { valid = NO; break; }
        total += count;
        CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
    }
    valid = valid && total == before.st_size && fstat(fd, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec;
    close(fd);
    if (!valid) { if (error) *error = RBXCloneError(84, @"exported IPA is malformed, changed, or has no verifiable clone ownership"); return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return @{@"path": path, @"containerId": container, @"bundleIdentifier": bundle,
        @"device": @(before.st_dev), @"inode": @(before.st_ino), @"sha256": hex};
}

static NSString *RBXExportQuarantineRoot(NSString *bundle) {
    return [@"/var/mobile/Library/RedditBox/deletion-exports" stringByAppendingPathComponent:bundle];
}

static BOOL RBXCleanExportRecord(NSDictionary *target, NSString *key, NSString *path, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    NSDictionary *record = target[key];
    NSString *root = RBXExportQuarantineRoot(target[@"bundleIdentifier"]);
    NSString *quarantine = [root stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"ipa"]];
    struct stat info;
    int rootStatus = lstat(root.fileSystemRepresentation, &info);
    if ((rootStatus == 0 && (!S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0077))) ||
        (rootStatus < 0 && errno != ENOENT)) {
        if (error) *error = RBXCloneError(84, @"export quarantine is unsafe or unreadable"); return NO;
    }
    int pendingStatus = lstat(quarantine.fileSystemRepresentation, &info);
    if (pendingStatus < 0 && errno != ENOENT) { if (error) *error = RBXCloneError(84, @"cannot inspect export quarantine"); return NO; }
    if (pendingStatus < 0) {
        NSError *readError = nil;
        NSDictionary *current = RBXExportIdentity(path, &readError);
        if (readError) { if (error) *error = readError; return NO; }
        // Never unlink a name after merely observing absence: another export
        // could occupy that mobile-writable name before the next syscall.
        if (!current) return RBXSyncArtifactParent(path, error);
        if ([key isEqualToString:@"sharedExport"] && ![target[@"containerId"] isEqual:current[@"containerId"]]) return YES;
        if (!record || ![current isEqual:record]) {
            if (error) *error = RBXCloneError(84, @"owned export changed or appeared after deletion preparation"); return NO;
        }
        if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
        for (NSString *directoryPath in @[root, root.stringByDeletingLastPathComponent]) {
            if (lstat(directoryPath.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) ||
                info.st_uid != 0 || (info.st_mode & 0077) || !RBXSyncArtifactParent(directoryPath, error)) {
                if (error && !*error) *error = RBXCloneError(84, @"cannot establish private export quarantine"); return NO;
            }
        }
        int sourceParent = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int privateParent = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        BOOL moved = sourceParent >= 0 && privateParent >= 0 && renameatx_np(sourceParent, path.lastPathComponent.fileSystemRepresentation,
            privateParent, quarantine.lastPathComponent.fileSystemRepresentation, RENAME_EXCL) == 0;
        BOOL durable = moved && fsync(sourceParent) == 0 && fsync(privateParent) == 0;
        if (sourceParent >= 0) close(sourceParent);
        if (privateParent >= 0) close(privateParent);
        if (!durable) { if (error) *error = RBXCloneError(84, @"export quarantine move is incomplete; retry with retained evidence"); return NO; }
    }
    NSError *readError = nil;
    NSMutableDictionary *captured = [RBXExportIdentity(quarantine, &readError) mutableCopy];
    captured[@"path"] = path;
    if (!record || !captured || ![captured isEqual:record]) {
        // A path replacement raced the move. Restore without overwriting any
        // newer export; otherwise retain the mismatched file in quarantine.
        if (renamex_np(quarantine.fileSystemRepresentation, path.fileSystemRepresentation, RENAME_EXCL) == 0) {
            RBXSyncArtifactParent(quarantine, nil); RBXSyncArtifactParent(path, nil);
        }
        if (error) *error = RBXCloneError(84, @"export identity changed during quarantine; content was restored or retained for recovery"); return NO;
    }
    if (!RBXRemoveArtifactPath(quarantine, error)) return NO;
    NSDictionary *replacement = RBXExportIdentity(path, &readError);
    if (readError) { if (error) *error = readError; return NO; }
    if (replacement && (![key isEqualToString:@"sharedExport"] ||
        [target[@"containerId"] isEqual:replacement[@"containerId"]])) {
        if (error) *error = RBXCloneError(84, @"another owned export appeared during deletion"); return NO;
    }
    return RBXSyncArtifactParent(path, error);
}

static NSString *RBXLegacyDeletionJobsRoot(NSString *bundle) {
    return [@"/var/mobile/Library/RedditBox/keychain-cleanup" stringByAppendingPathComponent:bundle];
}

static NSString *RBXDeletionJobsRoot(NSString *bundle) {
    // Rootless jailbreaks execute freshly signed helpers inside their bootstrap.
    // Keep durable jobs out of tmp; an upgrade must retain unproven-exit fences.
    if ([RBXInstalledScheme() isEqualToString:@"rootless"])
        return [RBXInstalledPath(@"/var/lib/redditbox/keychain-cleanup") stringByAppendingPathComponent:bundle];
    return RBXLegacyDeletionJobsRoot(bundle);
}

static BOOL RBXDeletionHelpersSafeAtRoot(NSString *root, NSError **error) {
    struct stat info;
    int status = lstat(root.fileSystemRepresentation, &info);
    if (status < 0 && errno == ENOENT) return YES;
    if (status != 0 || !S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0077)) {
        if (error) *error = RBXCloneError(81, @"deletion helper evidence directory is unsafe"); return NO;
    }
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:error];
    if (!entries) return NO;
    for (NSString *entry in entries) {
        NSString *job = [root stringByAppendingPathComponent:entry];
        if (![[NSUUID alloc] initWithUUIDString:entry] || lstat(job.fileSystemRepresentation, &info) != 0 ||
            !S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0077)) {
            if (error) *error = RBXCloneError(81, @"deletion helper evidence has an unowned job"); return NO;
        }
        NSString *fence = [job stringByAppendingPathComponent:@"helper-exit-unproven"];
        if (lstat(fence.fileSystemRepresentation, &info) == 0 || errno != ENOENT) {
            if (error) *error = RBXCloneError(81, @"a previous helper exit is unproven; retain its evidence for manual recovery before retrying deletion"); return NO;
        }
    }
    return YES;
}

static BOOL RBXDeletionHelpersSafe(NSString *bundle, NSError **error) {
    // Never lose an earlier release's recovery fence when the execution path changes.
    NSString *legacy = RBXLegacyDeletionJobsRoot(bundle), *current = RBXDeletionJobsRoot(bundle);
    return RBXDeletionHelpersSafeAtRoot(legacy, error) &&
        ([legacy isEqualToString:current] || RBXDeletionHelpersSafeAtRoot(current, error));
}

static NSString *RBXNewDeletionJob(NSString *bundle, NSError **error) {
    if (!RBXDeletionHelpersSafe(bundle, error)) return nil;
    NSString *root = RBXDeletionJobsRoot(bundle);
    if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error] || !RBXDeletionHelpersSafe(bundle, error)) return nil;
    NSString *job = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:job withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:error]) return nil;
    // Make the job discoverable after a crash before trusting its child fence.
    NSString *jobsParent = root.stringByDeletingLastPathComponent;
    NSString *dataParent = jobsParent.stringByDeletingLastPathComponent;
    for (NSString *path in @[job, root, jobsParent, dataParent, dataParent.stringByDeletingLastPathComponent]) {
        int directory = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        BOOL durable = directory >= 0 && fsync(directory) == 0;
        if (directory >= 0) close(directory);
        if (!durable) { if (error) *error = RBXCloneError(81, @"cannot persist the cleanup job directory chain"); return nil; }
    }
    return job;
}

static void RBXFinishDeletionJob(NSString *job) {
    if (!RBXCloneContinue(nil)) return;
    if (!job.length) return;
    struct stat info;
    NSString *fence = [job stringByAppendingPathComponent:@"helper-exit-unproven"];
    if (lstat(fence.fileSystemRepresentation, &info) < 0 && errno == ENOENT) RBXRemoveArtifactPath(job, nil);
}

static NSString *RBXShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'",
        [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static BOOL RBXSpawnCapturingStdout(NSString *executable, NSArray<NSString *> *arguments,
                                   NSString *outputPath, NSError **error) {
    return [RBXBoundedProcess runExecutable:executable arguments:arguments
        context:RBXOperationContext.currentContext outputPath:outputPath
        maximumOutputBytes:1024 * 1024 error:error];
}

static BOOL RBXMachOSliceIsEncrypted(const uint8_t *bytes, NSUInteger length,
                                     NSUInteger offset, NSUInteger sliceLength) {
    if (offset > length || sliceLength > length - offset ||
        sliceLength < sizeof(struct mach_header)) return YES;
    struct mach_header header;
    memcpy(&header, bytes + offset, sizeof(header));
    uint32_t magic = header.magic;
    BOOL swapped = magic == MH_CIGAM || magic == MH_CIGAM_64;
    BOOL is64 = magic == MH_MAGIC_64 || magic == MH_CIGAM_64;
    if (!(magic == MH_MAGIC || magic == MH_CIGAM || is64)) return YES;
    uint32_t ncmds = swapped ? OSSwapInt32(header.ncmds) : header.ncmds;
    uint32_t commandBytes = swapped ? OSSwapInt32(header.sizeofcmds) : header.sizeofcmds;
    NSUInteger headerSize = is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    if (headerSize > sliceLength || commandBytes > sliceLength - headerSize ||
        ncmds > commandBytes / sizeof(struct load_command)) return YES;
    NSUInteger cursor = offset + headerSize;
    NSUInteger commandsEnd = cursor + commandBytes;
    for (uint32_t index = 0; index < ncmds; index++) {
        if (sizeof(struct load_command) > commandsEnd - cursor) return YES;
        struct load_command load;
        memcpy(&load, bytes + cursor, sizeof(load));
        uint32_t command = swapped ? OSSwapInt32(load.cmd) : load.cmd;
        uint32_t commandSize = swapped ? OSSwapInt32(load.cmdsize) : load.cmdsize;
        if (commandSize < sizeof(load) || commandSize > commandsEnd - cursor || (commandSize & 3)) return YES;
        if (command == LC_ENCRYPTION_INFO) {
            if (commandSize < sizeof(struct encryption_info_command)) return YES;
            struct encryption_info_command encryption;
            memcpy(&encryption, bytes + cursor, sizeof(encryption));
            uint32_t cryptid = swapped ? OSSwapInt32(encryption.cryptid) : encryption.cryptid;
            if (cryptid != 0) return YES;
        } else if (command == LC_ENCRYPTION_INFO_64) {
            if (commandSize < sizeof(struct encryption_info_command_64)) return YES;
            struct encryption_info_command_64 encryption;
            memcpy(&encryption, bytes + cursor, sizeof(encryption));
            uint32_t cryptid = swapped ? OSSwapInt32(encryption.cryptid) : encryption.cryptid;
            if (cryptid != 0) return YES;
        }
        cursor += commandSize;
    }
    return cursor != commandsEnd;
}

static BOOL RBXMachOIsEncryptedAtPath(NSString *path) {
  @autoreleasepool {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:nil];
    if (data.length < sizeof(uint32_t)) return YES;
    const uint8_t *bytes = data.bytes;
    uint32_t magic = *(const uint32_t *)bytes;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        if (data.length < sizeof(struct fat_header)) return YES;
        BOOL swapped = magic == FAT_CIGAM;
        const struct fat_header *header = (const struct fat_header *)bytes;
        uint32_t count = swapped ? OSSwapInt32(header->nfat_arch) : header->nfat_arch;
        if (!count || count > 32 || data.length < sizeof(*header) + count * sizeof(struct fat_arch)) return YES;
        const struct fat_arch *architectures =
            (const struct fat_arch *)(bytes + sizeof(*header));
        for (uint32_t index = 0; index < count; index++) {
            uint32_t offset = swapped ? OSSwapInt32(architectures[index].offset)
                                      : architectures[index].offset;
            uint32_t size = swapped ? OSSwapInt32(architectures[index].size) : architectures[index].size;
            uint32_t alignment = swapped ? OSSwapInt32(architectures[index].align) : architectures[index].align;
            if (offset < sizeof(*header) + count * sizeof(struct fat_arch) || alignment > 30 ||
                (offset & ((1ULL << alignment) - 1)) ||
                RBXMachOSliceIsEncrypted(bytes, data.length, offset, size)) return YES;
            for (uint32_t earlier = 0; earlier < index; earlier++) {
                uint64_t start = swapped ? OSSwapInt32(architectures[earlier].offset) : architectures[earlier].offset;
                uint64_t span = swapped ? OSSwapInt32(architectures[earlier].size) : architectures[earlier].size;
                if (offset < start + span && start < (uint64_t)offset + size) return YES;
            }
        }
        return NO;
    }
    return RBXMachOSliceIsEncrypted(bytes, data.length, 0, data.length);
  }
}

static BOOL RBXIsMachOAtPath(NSString *path) {
    // Classification needs four bytes, never a retained copy of each resource.
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return NO;
    struct stat st;
    uint32_t magic = 0;
    BOOL read = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
        pread(fd, &magic, sizeof(magic), 0) == sizeof(magic);
    close(fd);
    return read && (magic == MH_MAGIC || magic == MH_CIGAM ||
           magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
           magic == FAT_MAGIC || magic == FAT_CIGAM ||
           magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
}

// No archive-provided links, ownership, ACLs or flags reach the filesystem.
// All destinations are beneath a newly created root-only staging directory.
static BOOL RBXExtractSourceZIP(int input, NSString *stage, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    struct archive *reader = archive_read_new();
    if (!reader) {
        if (error) *error = RBXCloneError(50, @"cannot allocate the source archive reader");
        return NO;
    }
    archive_read_support_format_zip(reader);
    archive_read_support_filter_none(reader);
    BOOL ok = NO;
    NSString *failure = nil;
    NSMutableSet *seen = [NSMutableSet set];
    uint64_t expanded = 0;
    NSUInteger entries = 0;
    if (archive_read_open_fd(reader, input, 65536) != ARCHIVE_OK) {
        failure = @"source file is not a readable ZIP IPA";
    } else {
        struct archive_entry *entry = NULL;
        int result;
        while ((result = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
          @autoreleasepool {
            if (!RBXCloneMayMutate(error)) { failure = @"source import was cancelled; staging is retained"; break; }
            const char *raw = archive_entry_pathname_utf8(entry);
            NSString *relative = raw ? [NSString stringWithUTF8String:raw] : nil;
            if ([relative hasSuffix:@"/"]) relative = [relative substringToIndex:relative.length - 1];
            NSArray *parts = [relative componentsSeparatedByString:@"/"];
            BOOL unsafe = !relative.length || relative.length > 2048 ||
                [relative hasPrefix:@"/"] || [relative containsString:@"\\"] ||
                [relative containsString:@":"] ||
                [relative rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound;
            for (NSString *part in parts)
                unsafe |= !part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."];
            NSString *canonical = [relative.precomposedStringWithCanonicalMapping lowercaseString];
            mode_t type = archive_entry_filetype(entry);
            if (unsafe || [seen containsObject:canonical] || ++entries > 65536 ||
                (type != AE_IFREG && type != AE_IFDIR) ||
                archive_entry_symlink(entry) || archive_entry_hardlink(entry) ||
                archive_entry_is_encrypted(entry) != 0) {
                failure = @"IPA contains unsafe, duplicate, encrypted or unsupported archive entries";
                break;
            }
            [seen addObject:canonical];
            int64_t size = archive_entry_size(entry);
            if (size < 0 || (type == AE_IFDIR && size != 0) || (uint64_t)size > 1024ULL * 1024 * 1024 ||
                expanded + (uint64_t)size > 3ULL * 1024 * 1024 * 1024) {
                failure = @"IPA exceeds the source import size limit"; break;
            }
            NSString *destination = [stage stringByAppendingPathComponent:relative];
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *directory = type == AE_IFDIR ? destination : destination.stringByDeletingLastPathComponent;
            if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0755} error:error]) break;
            if (type == AE_IFDIR) continue;
            int output = open(destination.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (output < 0) { failure = @"cannot create an imported source file"; break; }
            uint64_t written = 0;
            char buffer[65536];
            la_ssize_t count;
            while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                if (!RBXCloneMayMutate(error)) { failure = @"source import was cancelled; staging is retained"; break; }
                if (written + (uint64_t)count > (uint64_t)size) {
                    failure = @"IPA entry expands beyond its declared size"; break;
                }
                la_ssize_t offset = 0;
                while (offset < count) {
                    if (!RBXCloneMayMutate(error)) { failure = @"source import was cancelled; staging is retained"; break; }
                    ssize_t n = write(output, buffer + offset, (size_t)(count - offset));
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) { failure = @"source import write failed; check free storage"; break; }
                    offset += n;
                }
                if (failure) break;
                written += (uint64_t)count;
            }
            // Preserve only ordinary execute bits; never setuid/setgid or ACLs.
            mode_t mode = 0644 | (archive_entry_perm(entry) & 0111);
            if (!failure && (count < 0 || written != (uint64_t)size ||
                fchmod(output, mode) != 0 || fsync(output) != 0))
                failure = @"IPA entry is truncated, corrupt or could not be persisted";
            close(output);
            if (failure) break;
            expanded += written;
          }
        }
        ok = result == ARCHIVE_EOF && entries > 0 && !failure;
        if (!ok && !failure && (!error || !*error)) failure = @"source IPA is malformed or truncated";
    }
    if (archive_read_close(reader) != ARCHIVE_OK && ok) {
        ok = NO; failure = @"source IPA failed its final integrity check";
    }
    archive_read_free(reader);
    if (!ok && failure && error) *error = RBXCloneError(51, failure);
    return ok;
}

static BOOL RBXValidateImportedSource(NSString *bundle, NSDictionary *descriptor, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundle stringByAppendingPathComponent:@"Info.plist"]];
    NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class]
        ? info[@"CFBundleExecutable"] : nil;
    if (![descriptor[@"sourceBundleIdentifier"] isEqual:info[@"CFBundleIdentifier"]] ||
        !executable.length || ![executable isEqualToString:executable.lastPathComponent] ||
        [executable containsString:@"\\"] || [executable isEqualToString:@"."] ||
        [executable isEqualToString:@".."] ||
        ![@"APPL" isEqual:info[@"CFBundlePackageType"]] ||
        ![info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ||
        ![info[@"CFBundleVersion"] isKindOfClass:NSString.class] ||
        (info[@"CFBundleURLTypes"] && ![info[@"CFBundleURLTypes"] isKindOfClass:NSArray.class])) {
        if (error) *error = RBXCloneError(52, [NSString stringWithFormat:@"IPA must contain the original %@ application", descriptor[@"sourceBundleIdentifier"]]);
        return NO;
    }
    NSString *minimum = [info[@"MinimumOSVersion"] isKindOfClass:NSString.class]
        ? info[@"MinimumOSVersion"] : nil;
    if (!minimum.length || [minimum rangeOfString:@"^[0-9]{1,3}(\\.[0-9]{1,3}){0,2}$"
        options:NSRegularExpressionSearch].location == NSNotFound) {
        if (error) *error = RBXCloneError(55, [NSString stringWithFormat:@"%@ IPA has no valid MinimumOSVersion; select an original compatible decrypted build", descriptor[@"displayName"]]);
        return NO;
    }
    NSArray *parts = [minimum componentsSeparatedByString:@"."];
    NSOperatingSystemVersion required = { [parts[0] integerValue],
        parts.count > 1 ? [parts[1] integerValue] : 0,
        parts.count > 2 ? [parts[2] integerValue] : 0 };
    if (![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:required]) {
        if (error) *error = RBXCloneError(55, [NSString stringWithFormat:
            @"This %@ build requires iOS %@ or later. Import a build compatible with the physical phone; a synthetic profile cannot change executable OS requirements.", descriptor[@"displayName"], minimum]);
        return NO;
    }
    NSString *binary = [bundle stringByAppendingPathComponent:executable];
    if (!RBXIsMachOAtPath(binary) || RBXMachOIsEncryptedAtPath(binary)) {
        if (error) *error = RBXCloneError(53, [NSString stringWithFormat:@"%@ executable is encrypted or invalid; select a decrypted IPA", descriptor[@"displayName"]]);
        return NO;
    }
    // ZIP producers sometimes omit Unix executable permissions. Mach-O type is
    // verified before adding the owner execute bit needed by the clone builder.
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bundle];
    for (NSString *relative in enumerator) {
      @autoreleasepool {
        if (!RBXCloneMayMutate(error)) return NO;
        NSString *path = [bundle stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        if (![fm fileExistsAtPath:path isDirectory:&directory] || directory) continue;
        if (!RBXIsMachOAtPath(path)) continue;
        if (RBXMachOIsEncryptedAtPath(path) || chmod(path.fileSystemRepresentation, 0755) != 0) {
            if (error) *error = RBXCloneError(54, @"IPA contains an encrypted or invalid nested executable");
            return NO;
        }
      }
    }
    if (![fm isExecutableFileAtPath:binary]) {
        if (error) *error = RBXCloneError(54, [NSString stringWithFormat:@"%@ executable could not be prepared for cloning", descriptor[@"displayName"]]);
        return NO;
    }
    return YES;
}

static BOOL RBXSyncImportedTree(NSString *root, NSError **error) {
    if (!RBXCloneMayMutate(error)) return NO;
    __block NSError *enumerationError = nil;
    NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtURL:
        [NSURL fileURLWithPath:root] includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *failure) { enumerationError = failure; return NO; }];
    NSArray *paths = walk.allObjects;
    if (!paths || enumerationError) {
        if (error) *error = enumerationError ?: RBXCloneError(63, @"cannot enumerate imported source for verification");
        return NO;
    }
    NSMutableArray *ordered = [NSMutableArray arrayWithArray:paths.reverseObjectEnumerator.allObjects];
    [ordered addObject:[NSURL fileURLWithPath:root]];
    for (NSURL *url in ordered) {
        if (!RBXCloneMayMutate(error)) return NO;
        int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        BOOL ok = fd >= 0 && fsync(fd) == 0;
        if (fd >= 0) close(fd);
        if (!ok) {
            if (error) *error = RBXCloneError(63, @"cannot persist the complete imported source; previous source is unchanged");
            return NO;
        }
    }
    return YES;
}

@interface RBXCloneManager ()
@property(nonatomic, strong) RBXOperationContext *operationContext;
@property(nonatomic, readonly) NSString *sourceCachePath;
- (BOOL)_installIPA:(NSString *)ipa error:(NSError **)error;
- (BOOL)_uninstallBundleIdentifier:(NSString *)bundleIdentifier
                expectedBundlePath:(NSString *)bundlePath error:(NSError **)error;
- (BOOL)_copyBundleAtPath:(NSString *)source
                   toPath:(NSString *)destination
                    error:(NSError **)error;
- (NSString *)_installedBundleForIdentifier:(NSString *)bundleIdentifier;
- (BOOL)_recoverTransaction:(NSString *)root error:(NSError **)error;
- (BOOL)_recoverInterruptedTransactions:(NSError **)error;
- (BOOL)_archiveSourceAndRemoveVisibleApp:(NSError **)error;
- (BOOL)_removeCloneForProfile:(NSDictionary *)profile error:(NSError **)error;
- (NSDictionary *)_ensureCloneForContainer:(NSString *)containerId profile:(NSDictionary *)profile
                                  nickname:(NSString *)nickname error:(NSError **)error;
@end

static BOOL RBXBootstrapIsRedacted(NSString *bundlePath) {
    if (!bundlePath.length) return NO;
    NSData *data = [NSData dataWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"RedditBoxProfile.json"]];
    NSDictionary *profile = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [profile isKindOfClass:NSDictionary.class] && [RBXProfileForTransport(profile) isEqual:profile];
}

// A changed fingerprint must rebuild inside the existing install transaction,
// while the previous app and data are still available for backup/rollback.
static BOOL RBXBootstrapMatchesIdentity(NSString *bundlePath, NSDictionary *profile) {
    NSData *data = [NSData dataWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"RedditBoxProfile.json"]];
    NSDictionary *bootstrap = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![bootstrap isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!descriptor || ![RBXAppDescriptorForProfile(bootstrap) isEqual:descriptor]) return NO;
    for (NSString *key in @[@"containerId", @"device", @"serials", @"ids", @"timing", @"mgOverrides"])
        if (!profile[key] || ![bootstrap[key] isEqual:profile[key]]) return NO;
    if ([descriptor[@"appType"] isEqual:@"reddit"])
        return profile[@"reddit"] && [bootstrap[@"reddit"] isEqual:profile[@"reddit"]];
    NSString *namespace = descriptor[@"appType"];
    if ((profile[namespace] || bootstrap[namespace]) && ![bootstrap[namespace] isEqual:profile[namespace]]) return NO;
    NSString *bundle = RBXAppBundleIdentifier(descriptor, profile[@"containerId"]);
    for (NSDictionary *candidate in @[profile, bootstrap]) {
        if (RBXAppProfileIdentityBlockReason(descriptor, candidate, profile[@"containerId"]) ||
            ![candidate[@"app"][@"bundleIdentifier"] isEqual:bundle] ||
            !RBXAppKeychainMetadataMatches(descriptor, bundle, candidate[@"app"])) return NO;
    }
    return YES;
}

@implementation RBXCloneManager

// SGATE-002: enumerate registrations, never infer ownership from a process name.
+ (NSArray<NSDictionary *> *)storageTargetsWithError:(NSError **)error {
    NSDictionary *lookup=RBXInstalledApplication(@"com.redditbox.launcher",error);
    if(!lookup)return nil;
    id workspace=lookup[@"workspace"];
    SEL selector=NSSelectorFromString(@"allInstalledApplications");
    NSArray *apps=[workspace respondsToSelector:selector]?((id (*)(id,SEL))objc_msgSend)(workspace,selector):nil;
    if(![apps isKindOfClass:NSArray.class]||!apps.count){if(error)*error=RBXCloneError(92,@"Cannot enumerate registered clone storage");return nil;}
    NSMutableArray *targets=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(id proxy in apps){
        SEL identity=NSSelectorFromString(@"bundleIdentifier");
        NSString *bundle=[proxy respondsToSelector:identity]?((id (*)(id,SEL))objc_msgSend)(proxy,identity):nil;
        if(![bundle isKindOfClass:NSString.class]){if(error)*error=RBXCloneError(92,@"Invalid app registration identity");return nil;}
        NSDictionary *descriptor=RBXAppDescriptorForBundleIdentifier(bundle);
        if(!descriptor||!RBXAppOwnsCloneBundleIdentifier(descriptor,bundle))continue;
        if([seen containsObject:bundle]){if(error)*error=RBXCloneError(92,@"Duplicate clone registration");return nil;}[seen addObject:bundle];
        NSString *path=RBXProxyPath(proxy,@"bundleURL",error),*home=RBXProxyPath(proxy,@"dataContainerURL",error);
        if(!path||!home||!RBXManagedRemovalPath(path,@[@"/var/containers/Bundle/Application",@"/var/mobile/Containers/Bundle/Application"],YES,error)||!RBXValidateDataRemovalPath(home,bundle,NO,error))return nil;
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *marker=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:descriptor[@"cloneMarkerName"]]];
        NSString *cid=marker[@"containerId"],*main=info[@"CFBundleExecutable"];
        if(![cid isKindOfClass:NSString.class]||![RBXAppBundleIdentifier(descriptor,cid) isEqual:bundle]||![marker[@"bundleIdentifier"] isEqual:bundle]||!RBXAppKeychainMarkerMatches(descriptor,bundle,marker)||![info[@"CFBundleIdentifier"] isEqual:bundle]||![main isKindOfClass:NSString.class]||!main.length||![main isEqual:main.lastPathComponent]||[@[@".",@".."] containsObject:main]||[NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"PlugIns"]]){
            if(error)*error=RBXCloneError(92,@"Registered clone storage has invalid marker, keychain identity or executable");return nil;
        }
        [targets addObject:@{@"appType":descriptor[@"appType"],@"containerId":cid,@"bundleIdentifier":bundle,@"bundlePath":path,@"home":home,@"executable":[path stringByAppendingPathComponent:main]}];
    }
    return targets;
}

- (NSString *)sourceCachePath { return self.appDescriptor[@"sourceCachePath"]; }

- (BOOL)importSourceIPA:(NSString *)path error:(NSError **)error {
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_importSourceIPA:path error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)archiveSourceAndRemoveVisibleApp:(NSError **)error {
    if (![self.appDescriptor[@"runnable"] boolValue]) {
        if (error) *error = RBXCloneError(91, @"Visible source removal is unavailable for an inactive app; use the private IPA importer."); return NO;
    }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_archiveSourceAndRemoveVisibleApp:(&innerError)];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (NSDictionary *)ensureCloneForContainer:(NSString *)containerId
                                  profile:(NSDictionary *)profile
                                 nickname:(NSString *)nickname
                                    error:(NSError **)error {
    NSString *identityError = [containerId isKindOfClass:NSString.class] && containerId.length
        ? RBXAppProfileIdentityBlockReason(self.appDescriptor, profile, containerId)
        : @"Clone target has no valid container identity.";
    if (identityError) { if (error) *error = RBXCloneError(91, identityError); return nil; }
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile,
        [self.appDescriptor[@"runnable"] boolValue] || [[self sourceStatus][@"decrypted"] boolValue]);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return nil; }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return nil;
    }
    if (![context beginWork:error]) return nil;
    __block NSDictionary * result = nil;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_ensureCloneForContainer:containerId profile:profile nickname:nickname error:&innerError];
            if (![context check:&innerError]) result = nil;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)removeCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return NO; }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_removeCloneForProfile:profile error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (NSDictionary *)prepareDeletionForProfile:(NSDictionary *)profile error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return nil; }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return nil;
    }
    if (![context beginWork:error]) return nil;
    __block NSDictionary * result = nil;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_prepareDeletionForProfile:profile error:&innerError];
            if (![context check:&innerError]) result = nil;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)eraseKeychainForDeletionTarget:(NSDictionary *)target error:(NSError **)error {
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_eraseKeychainForDeletionTarget:target error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)uninstallDeletionTarget:(NSDictionary *)target error:(NSError **)error {
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_uninstallDeletionTarget:target error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)cleanupArtifactsForDeletionTarget:(NSDictionary *)target error:(NSError **)error {
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_cleanupArtifactsForDeletionTarget:target error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (NSString *)exportIPAForProfile:(NSDictionary *)profile error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return nil; }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return nil;
    }
    if (![context beginWork:error]) return nil;
    __block NSString * result = nil;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_exportIPAForProfile:profile error:&innerError];
            if (![context check:&innerError]) result = nil;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)syncProfile:(NSDictionary *)profile error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return NO; }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_syncProfile:profile error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (BOOL)writeControlPlist:(NSDictionary *)document
                  profile:(NSDictionary *)profile
                     name:(NSString *)name
                    error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return NO; }
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"A mutating operation context is required"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL result = NO;
    __block NSError *innerError = nil;
    @try {
        [context performBlock:^{
            if ([context check:&innerError]) result = [self _operation_writeControlPlist:document profile:profile name:name error:&innerError];
            if (![context check:&innerError]) result = NO;
        }];
    } @finally { [context endWork]; }
    if (!result && error) *error = innerError;
    return result;
}

- (instancetype)initWithAppType:(NSString *)appType operationContext:(RBXOperationContext *)context {
    NSDictionary *descriptor = RBXAppDescriptorForType(appType);
    if (!descriptor) return nil;
    if ((self = [super init])) { _operationContext = context; _appDescriptor = descriptor; }
    return self;
}
- (instancetype)initWithOperationContext:(RBXOperationContext *)context {
    return [self initWithAppType:@"reddit" operationContext:context];
}
- (instancetype)init { return [self initWithOperationContext:RBXOperationContext.currentContext]; }

// FBLIFE-004. Global startup/maintenance cannot report success after visiting
// only Reddit journals. Preflight all owners before replaying any operation.
+ (BOOL)recoverAllInterruptedTransactionsWithContext:(RBXOperationContext *)context error:(NSError **)error {
    if (!context || context.inspectionOnly || ![context check:error]) {
        if (error && !*error) *error = RBXCloneError(90, @"Global recovery requires a bounded mutating context");
        return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL success = NO;
    __block NSError *failure = nil;
    @try {
        [context performBlock:^{
            if (![context check:&failure]) return;
            int fd = RBXLockTransactions(&failure);
            if (fd < 0) return;
            @try {
                NSFileManager *fm = NSFileManager.defaultManager;
                NSArray *entries = [fm contentsOfDirectoryAtPath:RBXTransactionsRoot error:&failure];
                if (!entries) return;
                NSMutableArray *plan = [NSMutableArray array];
                for (NSString *entry in entries) {
                    if (![context check:&failure]) return;
                    NSString *root = [RBXTransactionsRoot stringByAppendingPathComponent:entry];
                    NSString *path = [root stringByAppendingPathComponent:@"transaction.plist"];
                    if (![fm fileExistsAtPath:path]) continue;
                    NSDictionary *record = RBXReadOwnedPlist(path, &failure);
                    NSDictionary *descriptor = RBXAppInstallationRecordDescriptor(record);
                    if (!descriptor) {
                        failure = failure ?: RBXCloneError(35, @"Global recovery found an unknown transaction owner; all journals were retained"); return;
                    }
                    if (![descriptor[@"runnable"] boolValue]) {
                        if (![@"committed" isEqual:record[@"state"]] && ![@"complete" isEqual:record[@"recoveryState"]]) {
                            failure = RBXCloneError(91, @"An inactive app has unfinished installation recovery; retain its journal and use a build supporting that app"); return;
                        }
                        continue; // Completed inactive backups are retained.
                    }
                    [plan addObject:@{@"root":root, @"descriptor":descriptor}];
                }
                for (NSDictionary *item in plan) {
                    if (![context check:&failure]) return;
                    RBXCloneManager *manager = [[self alloc] initWithAppType:item[@"descriptor"][@"appType"] operationContext:context];
                    if (!manager || ![manager _recoverTransaction:item[@"root"] error:&failure]) return;
                }
                success = [context check:&failure];
            } @finally { flock(fd, LOCK_UN); close(fd); }
        }];
    } @finally {
        NSError *sealError=nil;
        if(![RBXStorageAccess closeAll:&sealError]){success=NO;failure=sealError;}
        [context endWork];
    }
    if (!success && error) *error = failure;
    return success;
}

- (void)recoverInterruptedTransactions {
    NSError *error = nil;
    RBXOperationContext *context = self.operationContext ?: RBXOperationContext.currentContext;
    if (![self recoverInterruptedTransactionsWithContext:context error:&error])
        NSLog(@"redditboxd: recovery deferred: %@", error.localizedDescription);
}
- (BOOL)recoverInterruptedTransactionsWithContext:(RBXOperationContext *)context error:(NSError **)error {
    if (![self.appDescriptor[@"runnable"] boolValue]) {
        if (error) *error = RBXCloneError(91, @"Recovery for this inactive app requires its lifecycle audit."); return NO;
    }
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXCloneError(90, @"Recovery requires a bounded mutating context"); return NO;
    }
    if (![context beginWork:error]) return NO;
    __block BOOL success = NO;
    __block NSError *failure = nil;
    @try {
        [context performBlock:^{
            if (![context check:&failure]) return;
            int fd = RBXLockTransactions(&failure);
            if (fd < 0) return;
            @try { success = [self _recoverInterruptedTransactions:&failure]; }
            @finally { flock(fd, LOCK_UN); close(fd); }
        }];
    } @finally {
        NSError *sealError=nil;
        if(![RBXStorageAccess closeAll:&sealError]){success=NO;failure=sealError;}
        [context endWork];
    }
    if (!success && error) *error = failure;
    return success;
}
- (BOOL)_recoverInterruptedTransactions:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *entries = [fm contentsOfDirectoryAtPath:RBXTransactionsRoot error:error];
    if (!entries) return NO;
    for (NSString *entry in entries) {
        if (!RBXCloneMayMutate(error)) return NO;
        NSString *root = [RBXTransactionsRoot stringByAppendingPathComponent:entry];
        if (![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"transaction.plist"]]) continue;
        NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"transaction.plist"]];
        NSDictionary *owner = RBXAppInstallationRecordDescriptor(record);
        if (!owner) { if (error) *error = RBXCloneError(35, @"unknown transaction owner; preserve it for recovery"); return NO; }
        if ([owner isEqual:self.appDescriptor] && ![self _recoverTransaction:root error:error]) return NO;
    }
    return RBXCloneMayMutate(error);
}

- (BOOL)_snapshotData:(NSString *)source toPath:(NSString *)destination error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *temporary = [destination stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![self _copyBundleAtPath:source toPath:temporary error:error] ||
        ![fm contentsEqualAtPath:source andPath:temporary]) {
        if (error && !*error) *error = RBXCloneError(34, @"data snapshot could not be verified");
        return NO;
    }
    return RBXCloneMayMutate(error) && [fm moveItemAtPath:temporary toPath:destination error:error];
}

- (BOOL)_restoreData:(NSString *)snapshot toContainer:(NSString *)container error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *current = [fm contentsOfDirectoryAtPath:container error:error];
    NSArray *saved = [fm contentsOfDirectoryAtPath:snapshot error:error];
    if (!current || !saved) return NO;
    // Both the original and failed-install sandbox are already retained outside
    // the installed app. Preserve iOS's metadata for the newly allocated sandbox.
    for (NSString *entry in current) {
        if (!RBXCloneMayMutate(error)) return NO;
        if ([entry hasPrefix:@".com.apple.mobile_container_manager"]) continue;
        if (![fm removeItemAtPath:[container stringByAppendingPathComponent:entry] error:error]) return NO;
    }
    for (NSString *entry in saved) {
        if (!RBXCloneMayMutate(error)) return NO;
        if ([entry hasPrefix:@".com.apple.mobile_container_manager"]) continue;
        NSString *source = [snapshot stringByAppendingPathComponent:entry];
        NSString *target = [container stringByAppendingPathComponent:entry];
        if (![self _copyBundleAtPath:source toPath:target error:error] ||
            ![fm contentsEqualAtPath:source andPath:target]) return NO;
    }
    return YES;
}

- (BOOL)_recoverTransaction:(NSString *)root error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *journal = [[NSDictionary dictionaryWithContentsOfFile:
        [root stringByAppendingPathComponent:@"transaction.plist"]] mutableCopy];
    NSString *bundle = journal[@"bundleIdentifier"];
    NSString *phase = journal[@"state"];
    if (!RBXAppInstallationRecordOwnedBy(journal, self.appDescriptor) || ![phase isKindOfClass:NSString.class]) {
        if (error) *error = RBXCloneError(35, @"unknown transaction; preserve it for manual recovery");
        return NO;
    }
    if (!RBXContainerAvailable(journal[@"containerId"], error)) return NO;
    // The old version-3 producer boxed this one C comparison as integer 0/1.
    // Ownership validation above accepts only that exact legacy form. Persist
    // its canonical boolean before any replay or destructive recovery work.
    if (RBXAppKeychainMappingEnabled(self.appDescriptor) &&
        CFGetTypeID((__bridge CFTypeRef)journal[@"hadPreviousInstall"]) != CFBooleanGetTypeID()) {
        journal[@"hadPreviousInstall"] = [journal[@"hadPreviousInstall"] boolValue] ? @YES : @NO;
        if (!RBXWriteJournal(root, journal, phase, error)) return NO;
    }
    if ([phase isEqualToString:@"prepared"] || [phase isEqualToString:@"committed"])
        return [fm removeItemAtPath:root error:error];
    if ([journal[@"recoveryState"] isEqualToString:@"complete"]) return YES;
    if (![@[@"install-attempted", @"installed"] containsObject:phase]) {
        if (error) *error = RBXCloneError(35, @"unrecognized recovery phase"); return NO;
    }
    if (![[[RBXProcessController alloc] initWithAppDescriptor:self.appDescriptor] killAllAndWait:8.0]) {
        if (error) *error = RBXCloneError(42, @"cannot quiesce processes for clone recovery");
        return NO;
    }
    NSString *previousBundle = [root stringByAppendingPathComponent:[@"backup/Payload" stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]]];
    NSString *previousIPA = [root stringByAppendingPathComponent:@"previous.ipa"];
    NSString *previousData = [root stringByAppendingPathComponent:@"previous-data"];
    BOOL hadPrevious = [journal[@"hadPreviousInstall"] boolValue];
    if (hadPrevious && (![fm fileExistsAtPath:previousIPA] ||
                        ![fm fileExistsAtPath:previousData] ||
                        ![fm fileExistsAtPath:previousBundle])) {
        if (error) *error = RBXCloneError(36, @"previous install/data backup is incomplete; recovery stopped");
        return NO;
    }
    if (hadPrevious && RBXAppKeychainMappingEnabled(self.appDescriptor)) {
        NSDictionary *savedMarker = [NSDictionary dictionaryWithContentsOfFile:[previousBundle stringByAppendingPathComponent:self.appDescriptor[@"cloneMarkerName"]]];
        NSDictionary *savedInfo = [NSDictionary dictionaryWithContentsOfFile:[previousBundle stringByAppendingPathComponent:@"Info.plist"]];
        if (![bundle isEqual:savedInfo[@"CFBundleIdentifier"]] || ![bundle isEqual:savedMarker[@"bundleIdentifier"]] ||
            ![journal[@"containerId"] isEqual:savedMarker[@"containerId"]] || !RBXAppKeychainMarkerMatches(self.appDescriptor, bundle, savedMarker)) {
            if (error) *error = RBXCloneError(36, @"previous installation backup does not match the complete app identity; recovery stopped"); return NO;
        }
    }
    NSString *pendingPath = [[[RBXTransactionsRoot stringByAppendingPathComponent:@"uninstall-evidence"]
        stringByAppendingPathComponent:bundle] stringByAppendingPathComponent:@"transaction.plist"];
    NSError *pendingError = nil;
    NSDictionary *pending = RBXReadOwnedPlist(pendingPath, &pendingError);
    if (pendingError) { if (error) *error = pendingError; return NO; }
    if (pending) {
        NSString *failedSnapshot = [root stringByAppendingPathComponent:@"failed-install-data"];
        NSDictionary *dataOwner = [NSDictionary dictionaryWithContentsOfFile:[failedSnapshot
            stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        struct stat saved;
        if (hadPrevious || ![@YES isEqual:journal[@"recoveryStarted"]] ||
            ![root.lastPathComponent isEqual:pending[@"installationTransaction"]] ||
            ![bundle isEqual:pending[@"bundleIdentifier"]] ||
            ![pending[@"pluginIDs"] isKindOfClass:NSArray.class] || [pending[@"pluginIDs"] count] ||
            lstat(failedSnapshot.fileSystemRepresentation, &saved) != 0 || !S_ISDIR(saved.st_mode) ||
            ![bundle isEqual:dataOwner[@"MCMMetadataIdentifier"]]) {
            if (error) *error = RBXCloneError(39, @"pending rollback removal lacks its exact transaction and preserved data proof"); return NO;
        }
        if (![self _uninstallBundleIdentifier:bundle expectedBundlePath:pending[@"bundlePath"] error:error]) return NO;
        journal[@"recoveryState"] = @"complete";
        return RBXWriteJournal(root, journal, phase, error);
    }
    NSDictionary *registration = RBXInstalledApplication(bundle, error);
    if (!registration) return NO;
    NSDictionary *installedCapture = registration[@"proxy"]
        ? RBXCaptureRemoval(registration[@"proxy"], bundle, nil, error) : nil;
    if (registration[@"proxy"] && !installedCapture) return NO;
    NSString *current = installedCapture[@"bundlePath"];
    NSDictionary *marker = current.length ? [NSDictionary dictionaryWithContentsOfFile:
        [current stringByAppendingPathComponent:@".redditbox-clone.plist"]] : nil;
    if (current.length && RBXAppKeychainMappingEnabled(self.appDescriptor) &&
        (![bundle isEqual:marker[@"bundleIdentifier"]] || ![journal[@"containerId"] isEqual:marker[@"containerId"]] ||
         !RBXAppKeychainMarkerMatches(self.appDescriptor, bundle, marker))) {
        if (error) *error = RBXCloneError(37, @"installed clone does not match the complete app recovery identity"); return NO;
    }
    BOOL previousUnchanged = hadPrevious && current.length &&
        [fm contentsEqualAtPath:current andPath:previousBundle];
    if (current.length && !previousUnchanged &&
        ![marker[@"installationTransaction"] isEqualToString:root.lastPathComponent]) {
        if (error) *error = RBXCloneError(37, @"installed app belongs to another or unknown transaction");
        return NO;
    }
    NSString *data = installedCapture[@"dataPath"];
    NSString *failedData = [root stringByAppendingPathComponent:@"failed-install-data"];
    if (data.length && ![fm fileExistsAtPath:failedData] &&
        ![self _snapshotData:data toPath:failedData error:error]) return NO;
    BOOL dataUnchanged = hadPrevious && data.length &&
        [fm contentsEqualAtPath:data andPath:previousData];
    if (previousUnchanged && dataUnchanged && ![journal[@"recoveryStarted"] boolValue]) {
        // Installer was never reached or left the previous installation intact.
        // No uninstall, reinstall, or sandbox rewrite is necessary.
        journal[@"recoveryState"] = @"complete";
        return RBXWriteJournal(root, journal, phase, error);
    }
    journal[@"recoveryStarted"] = @YES;
    if (!RBXWriteJournal(root, journal, phase, error)) return NO;
    if (hadPrevious) {
        // Restore IN PLACE: never uninstall an existing working installation.
        if (!RBXNoPendingRemoval(bundle, error)) return NO;
        if (!previousUnchanged && ![self _installIPA:previousIPA error:error]) return NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        do {
            if (!RBXCloneMayMutate(error)) return NO;
            current = [self _installedBundleForIdentifier:bundle];
            data = [self dataContainerForBundleIdentifier:bundle];
            if (current.length && data.length &&
                [fm contentsEqualAtPath:current andPath:previousBundle]) break;
            [NSThread sleepForTimeInterval:0.1];
        } while (deadline.timeIntervalSinceNow > 0);
        if (!current.length || !data.length ||
            ![fm contentsEqualAtPath:current andPath:previousBundle] ||
            ![self _restoreData:previousData toContainer:data error:error]) {
            if (error && !*error) *error = RBXCloneError(38, @"previous installation/data restoration failed");
            return NO;
        }
    } else {
        // Current clonedApp-v2 bundles contain no extensions. Refuse an
        // unexpected older layout rather than erase plugin data not included
        // in the existing failed-install data snapshot.
        if ([installedCapture[@"pluginIDs"] count]) {
            if (error) *error = RBXCloneError(39, @"recovery found unexpected plugin data; retain the transaction for manual recovery"); return NO;
        }
        if (![self _uninstallBundleIdentifier:bundle expectedBundlePath:current error:error]) return NO;
    }
    // Keep both snapshots even after successful rollback: failed-install data
    // may include user changes. A later attempt ignores completed recovery.
    journal[@"recoveryState"] = @"complete";
    return RBXWriteJournal(root, journal, phase, error);
}

+ (NSString *)bundleIdentifierForContainer:(NSString *)containerId {
    return RBXAppBundleIdentifier(RBXRedditAppDescriptor(), containerId);
}
+ (NSString *)bundleIdentifierForContainer:(NSString *)containerId appType:(NSString *)appType {
    return RBXAppBundleIdentifier(RBXAppDescriptorForType(appType), containerId);
}
+ (NSString *)keychainGroupForBundleIdentifier:(NSString *)bundleIdentifier {
    return RBXAppKeychainGroup(RBXRedditAppDescriptor(), bundleIdentifier);
}
+ (NSString *)keychainGroupForBundleIdentifier:(NSString *)bundleIdentifier appType:(NSString *)appType {
    return RBXAppKeychainGroup(RBXAppDescriptorForType(appType), bundleIdentifier);
}

- (NSString *)_sourceRedditBundle {
    NSDictionary *cachedInfo = [NSDictionary dictionaryWithContentsOfFile:
        [self.sourceCachePath stringByAppendingPathComponent:@"Info.plist"]];
    if ([cachedInfo[@"CFBundleIdentifier"] isEqualToString:(self.appDescriptor[@"sourceBundleIdentifier"])]) {
        return self.sourceCachePath;
    }
    if (![self.appDescriptor[@"runnable"] boolValue]) return nil;
    NSArray<NSString *> *roots = @[@"/var/containers/Bundle/Application",
                                    @"/var/mobile/Containers/Bundle/Application",
                                    @"/Applications",
                                    @"/var/jb/Applications"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *child in children) {
            NSString *candidate = [root stringByAppendingPathComponent:child];
            BOOL isDirectory = NO;
            [fm fileExistsAtPath:candidate isDirectory:&isDirectory];
            if (!isDirectory) continue;
            if (![candidate.pathExtension.lowercaseString isEqualToString:@"app"]) {
                candidate = [candidate stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]];
            }
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [candidate stringByAppendingPathComponent:@"Info.plist"]];
            if ([info[@"CFBundleIdentifier"] isEqualToString:(self.appDescriptor[@"sourceBundleIdentifier"])]) return candidate;
        }
    }
    return nil;
}

- (NSDictionary *)creationSourceBinding {
    NSString *path = [self _sourceRedditBundle];
    NSDictionary *info = path ? [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]] : nil;
    NSString *exe = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
    if (!exe.length || ![exe isEqual:exe.lastPathComponent] || [@[@".", @".."] containsObject:exe]) return nil;
    NSMutableArray *identities = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSString *component in @[path, [path stringByAppendingPathComponent:@"Info.plist"], [path stringByAppendingPathComponent:exe]]) {
        struct stat entry;
        if (lstat(component.fileSystemRepresentation, &entry) != 0 || S_ISLNK(entry.st_mode) ||
            (index == 0 ? !S_ISDIR(entry.st_mode) : !S_ISREG(entry.st_mode))) return nil;
        index++;
        [identities addObject:@{@"dev":@(entry.st_dev), @"ino":@(entry.st_ino), @"size":@(entry.st_size),
            @"mtime":@(entry.st_mtimespec.tv_sec), @"mtimeNanos":@(entry.st_mtimespec.tv_nsec),
            @"ctime":@(entry.st_ctimespec.tv_sec), @"ctimeNanos":@(entry.st_ctimespec.tv_nsec)}];
    }
    return @{@"path":path, @"entries":identities};
}

- (NSDictionary *)sourceStatus {
    NSString *path = [self _sourceRedditBundle];
    NSDictionary *info = path.length ? [NSDictionary dictionaryWithContentsOfFile:
        [path stringByAppendingPathComponent:@"Info.plist"]] : nil;
    NSString *binary = path.length ? [path stringByAppendingPathComponent:
        info[@"CFBundleExecutable"] ?: @""] : nil;
    BOOL executable = binary.length &&
        [NSFileManager.defaultManager isExecutableFileAtPath:binary];
    BOOL decrypted = executable && !RBXMachOIsEncryptedAtPath(binary);
    return @{
        @"found": @(path.length > 0),
        @"decrypted": @(decrypted),
        @"location": [path isEqualToString:self.sourceCachePath]
            ? @"private-cache" : (path.length ? @"installed-app" : @"missing"),
        @"version": [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]]
            ? info[@"CFBundleShortVersionString"] : @"",
        @"build": [info[@"CFBundleVersion"] isKindOfClass:[NSString class]]
            ? info[@"CFBundleVersion"] : @"",
        @"message": !path.length ? [NSString stringWithFormat:@"No %@ source found", self.appDescriptor[@"displayName"]] :
            (decrypted ? [NSString stringWithFormat:@"Decrypted %@ source ready", self.appDescriptor[@"displayName"]] :
                [NSString stringWithFormat:@"%@ source is encrypted or invalid", self.appDescriptor[@"displayName"]]),
    };
}

- (BOOL)_operation_importSourceIPA:(NSString *)path error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *name = [path isKindOfClass:NSString.class] ? path.lastPathComponent : nil;
    NSUUID *identifier = name.length ? [[NSUUID alloc] initWithUUIDString:name.stringByDeletingPathExtension] : nil;
    if (!identifier || ![name.pathExtension isEqualToString:@"ipa"] ||
        ![path.stringByDeletingLastPathComponent isEqualToString:self.appDescriptor[@"sourceInboxPath"]] ||
        ![path isEqualToString:path.stringByStandardizingPath]) {
        if (error) *error = RBXCloneError(55, @"select an IPA with Import Reddit Source in Settings");
        return NO;
    }
    // Open each caller-writable component without following links. The signed
    // launcher completes its copy before submitting this path over IPC.
    int library = open("/var/mobile/Library", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    int root = library >= 0 ? openat(library, "RedditBox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW) : -1;
    int inbox = root >= 0 ? openat(root, "SourceInbox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW) : -1;
    int input = inbox >= 0 ? openat(inbox, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW) : -1;
    struct stat inputStat, rootStat;
    BOOL safe = input >= 0 && fstat(input, &inputStat) == 0 && S_ISREG(inputStat.st_mode) &&
        inputStat.st_nlink == 1 && inputStat.st_size > 0 && inputStat.st_size <= 2LL * 1024 * 1024 * 1024 &&
        fstat(root, &rootStat) == 0 && rootStat.st_uid == 0 && !(rootStat.st_mode & 0022);
    if (library >= 0) close(library);
    if (!safe) {
        if (input >= 0) close(input);
        if (inbox >= 0) close(inbox);
        if (root >= 0) close(root);
        if (error) *error = RBXCloneError(56, @"source inbox is unsafe, unreadable or exceeds the 2 GiB IPA limit; retry staging from Settings");
        return NO;
    }
    int lock = RBXLockTransactions(error);
    if (lock < 0) { close(input); close(inbox); close(root); return NO; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *sourceRoot = self.sourceCachePath.stringByDeletingLastPathComponent;
    NSString *stage = [sourceRoot stringByAppendingPathComponent:
        [NSString stringWithFormat:@".import-%@", NSUUID.UUID.UUIDString]];
    BOOL preserveStage = NO;
    BOOL stageCreated = NO;
    @try {
        if (mkdirat(root, [self.appDescriptor[@"sourceDirectoryName"] fileSystemRepresentation], 0700) != 0 && errno != EEXIST) {
            if (error) *error = RBXCloneError(57, @"cannot create the private source directory"); return NO;
        }
        int source = openat(root, [self.appDescriptor[@"sourceDirectoryName"] fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        struct stat sourceStat;
        safe = source >= 0 && fstat(source, &sourceStat) == 0 &&
            sourceStat.st_uid == 0 && !(sourceStat.st_mode & 0077);
        if (source >= 0) close(source);
        if (!safe) {
            if (error) *error = RBXCloneError(58, @"private source directory must be root-owned with mode 0700"); return NO;
        }
        if (![fm createDirectoryAtPath:stage withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
        stageCreated = YES;
        if (!RBXExtractSourceZIP(input, stage, error)) return NO;
        NSString *payload = [stage stringByAppendingPathComponent:@"Payload"];
        NSArray *applications = [fm contentsOfDirectoryAtPath:payload error:error];
        NSString *application = applications.count == 1 ? applications.firstObject : nil;
        NSString *stagedBundle = application ? [payload stringByAppendingPathComponent:application] : nil;
        BOOL directory = NO;
        if (![application.pathExtension isEqualToString:@"app"] ||
            ![fm fileExistsAtPath:stagedBundle isDirectory:&directory] || !directory) {
            if (error) *error = RBXCloneError(59, @"IPA must contain exactly one application in Payload"); return NO;
        }
        if (!RBXValidateImportedSource(stagedBundle, self.appDescriptor, error) ||
            !RBXSyncImportedTree(stage, error)) return NO;
        // A swap publishes the complete directory in one filesystem operation.
        // The existing cache remains at stagedBundle until publication is synced.
        struct stat previous;
        BOOL existed = lstat(self.sourceCachePath.fileSystemRepresentation, &previous) == 0;
        if ((!existed && errno != ENOENT) || (existed && !S_ISDIR(previous.st_mode))) {
            if (error) *error = RBXCloneError(60, @"existing private source cannot be safely replaced"); return NO;
        }
        if (!RBXCloneMayMutate(error)) return NO;
        int result = existed
            ? renamex_np(stagedBundle.fileSystemRepresentation, self.sourceCachePath.fileSystemRepresentation, RENAME_SWAP)
            : rename(stagedBundle.fileSystemRepresentation, self.sourceCachePath.fileSystemRepresentation);
        if (result != 0) {
            if (error) *error = RBXCloneError(61, @"atomic source replacement failed; previous source is unchanged"); return NO;
        }
        int directoryFD = open(sourceRoot.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int payloadFD = open(payload.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        BOOL durable = directoryFD >= 0 && payloadFD >= 0 &&
            fsync(payloadFD) == 0 && fsync(directoryFD) == 0;
        if (payloadFD >= 0) close(payloadFD);
        if (directoryFD >= 0) close(directoryFD);
        if (!durable) {
            if (!RBXCloneMayMutate(error)) { preserveStage = YES; return NO; }
            int rollback = existed
                ? renamex_np(stagedBundle.fileSystemRepresentation, self.sourceCachePath.fileSystemRepresentation, RENAME_SWAP)
                : rename(self.sourceCachePath.fileSystemRepresentation, stagedBundle.fileSystemRepresentation);
            preserveStage = rollback != 0;
            if (error) *error = RBXCloneError(62, preserveStage
                ? [NSString stringWithFormat:@"source durability check failed; recovery copy retained at %@", stage]
                : @"source durability check failed; previous source restored");
            return NO;
        }
        // Never unlink an inbox entry that another staging request replaced.
        struct stat finalInput;
        if (fstatat(inbox, name.fileSystemRepresentation, &finalInput, AT_SYMLINK_NOFOLLOW) == 0 &&
            finalInput.st_ino == inputStat.st_ino && finalInput.st_dev == inputStat.st_dev)
            unlinkat(inbox, name.fileSystemRepresentation, 0);
        NSLog(@"redditboxd: decrypted %@ IPA imported into the private source cache", self.appDescriptor[@"displayName"]);
        return YES;
    } @finally {
        if (stageCreated && !preserveStage && RBXCloneContinue(nil)) [fm removeItemAtPath:stage error:nil];
        close(input); close(inbox); close(root);
        flock(lock, LOCK_UN); close(lock);
    }
}

- (NSString *)_installedBundleForIdentifier:(NSString *)bundleIdentifier {
    NSArray<NSString *> *roots = @[@"/var/containers/Bundle/Application",
                                    @"/var/mobile/Containers/Bundle/Application"];
    for (NSString *root in roots) {
        if (!RBXCloneContinue(nil)) return nil;
        NSDirectoryEnumerator *enumerator =
            [NSFileManager.defaultManager enumeratorAtPath:root];
        for (NSString *relative in enumerator) {
            if (!RBXCloneContinue(nil)) return nil;
            if (![relative.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *candidate = [root stringByAppendingPathComponent:relative];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [candidate stringByAppendingPathComponent:@"Info.plist"]];
            if ([info[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) {
                return candidate;
            }
            [enumerator skipDescendants];
        }
    }
    return nil;
}

- (BOOL)_operation_archiveSourceAndRemoveVisibleApp:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return NO;
    @try { return [self _archiveSourceAndRemoveVisibleApp:error]; }
    @finally { flock(fd, LOCK_UN); close(fd); }
}

- (BOOL)_archiveSourceAndRemoveVisibleApp:(NSError **)error {
    NSString *pendingPath = [[[RBXTransactionsRoot stringByAppendingPathComponent:@"uninstall-evidence"]
        stringByAppendingPathComponent:(self.appDescriptor[@"sourceBundleIdentifier"])] stringByAppendingPathComponent:@"transaction.plist"];
    NSError *pendingError = nil;
    NSDictionary *pending = RBXReadOwnedPlist(pendingPath, &pendingError);
    if (pendingError) { if (error) *error = pendingError; return NO; }
    if (pending) {
        NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:[self.sourceCachePath stringByAppendingPathComponent:@"Info.plist"]];
        NSString *name = [cached[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? cached[@"CFBundleExecutable"] : nil;
        NSString *binary = name ? [self.sourceCachePath stringByAppendingPathComponent:name] : nil;
        if (![(self.appDescriptor[@"sourceBundleIdentifier"]) isEqual:pending[@"bundleIdentifier"]] || ![(self.appDescriptor[@"sourceBundleIdentifier"]) isEqual:cached[@"CFBundleIdentifier"]] ||
            !name.length || ![name isEqual:name.lastPathComponent] || [@[@".", @".."] containsObject:name] ||
            ![NSFileManager.defaultManager isExecutableFileAtPath:binary] || RBXMachOIsEncryptedAtPath(binary)) {
            if (error) *error = RBXCloneError(41, @"source removal retry requires the retained valid decrypted private source"); return NO;
        }
        return [self _uninstallBundleIdentifier:(self.appDescriptor[@"sourceBundleIdentifier"]) expectedBundlePath:pending[@"bundlePath"] error:error];
    }
    NSDictionary *registration = RBXInstalledApplication((self.appDescriptor[@"sourceBundleIdentifier"]), error);
    if (!registration) return NO;
    NSDictionary *capture = registration[@"proxy"]
        ? RBXCaptureRemoval(registration[@"proxy"], (self.appDescriptor[@"sourceBundleIdentifier"]), nil, error) : nil;
    if (registration[@"proxy"] && !capture) return NO;
    NSString *registered = capture[@"bundlePath"];
    if (!registered.length) {
        NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:
            [self.sourceCachePath stringByAppendingPathComponent:@"Info.plist"]];
        if ([cached[@"CFBundleIdentifier"] isEqualToString:(self.appDescriptor[@"sourceBundleIdentifier"])])
            return [self _uninstallBundleIdentifier:(self.appDescriptor[@"sourceBundleIdentifier"]) expectedBundlePath:nil error:error];
        if (error) *error = RBXCloneError(38, @"visible decrypted Reddit source is not installed");
        return NO;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [registered stringByAppendingPathComponent:@"Info.plist"]];
    NSString *binary = [registered stringByAppendingPathComponent:
        info[@"CFBundleExecutable"] ?: @""];
    if (RBXMachOIsEncryptedAtPath(binary)) {
        if (error) *error = RBXCloneError(39,
            @"source is encrypted; it cannot be archived for future cloning");
        return NO;
    }
    NSString *sourceRoot = self.sourceCachePath.stringByDeletingLastPathComponent;
    NSString *staged = [sourceRoot stringByAppendingPathComponent:
        [NSString stringWithFormat:@".Reddit-%@.app", NSUUID.UUID.UUIDString]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:sourceRoot withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error] ||
        ![self _copyBundleAtPath:registered toPath:staged error:error]) {
        [fm removeItemAtPath:staged error:nil];
        return NO;
    }
    NSDictionary *copiedInfo = [NSDictionary dictionaryWithContentsOfFile:
        [staged stringByAppendingPathComponent:@"Info.plist"]];
    NSString *copiedBinary = [staged stringByAppendingPathComponent:
        copiedInfo[@"CFBundleExecutable"] ?: @""];
    if (![copiedInfo[@"CFBundleIdentifier"] isEqualToString:(self.appDescriptor[@"sourceBundleIdentifier"])] ||
        ![fm isExecutableFileAtPath:copiedBinary] ||
        RBXMachOIsEncryptedAtPath(copiedBinary)) {
        [fm removeItemAtPath:staged error:nil];
        if (error) *error = RBXCloneError(40, @"private source copy failed validation");
        return NO;
    }
    [fm removeItemAtPath:self.sourceCachePath error:nil];
    if (![fm moveItemAtPath:staged toPath:self.sourceCachePath error:error]) return NO;
    chmod(sourceRoot.fileSystemRepresentation, 0700);
    if (![self _uninstallBundleIdentifier:(self.appDescriptor[@"sourceBundleIdentifier"]) expectedBundlePath:registered error:error]) return NO;
    NSLog(@"redditboxd: decrypted Reddit source archived privately; visible source uninstalled");
    return YES;
}

- (BOOL)_copyBundleAtPath:(NSString *)source toPath:(NSString *)destination error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:destination error:nil];
    [fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    copyfile_flags_t flags = COPYFILE_ALL | COPYFILE_RECURSIVE;
#ifdef COPYFILE_CLONE
    flags |= COPYFILE_CLONE;
#endif
    copyfile_state_t state = copyfile_state_alloc();
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!state || copyfile_state_set(state, COPYFILE_STATE_STATUS_CB, (void *)RBXCopyProgress) != 0 ||
        copyfile_state_set(state, COPYFILE_STATE_STATUS_CTX, (__bridge void *)context) != 0) {
        if (state) copyfile_state_free(state);
        if (error) *error = RBXCloneError(10, @"cannot configure cancellable bundle copy"); return NO;
    }
    int result = copyfile(source.fileSystemRepresentation, destination.fileSystemRepresentation, state, flags);
    copyfile_state_free(state);
    if (!RBXCloneMayMutate(error)) return NO;
    if (result == 0) return YES;
    NSError *copyError = nil;
    if ([fm copyItemAtPath:source toPath:destination error:&copyError]) return YES;
    if (error) *error = copyError ?: RBXCloneError(10, @"cannot copy the source app bundle");
    return NO;
}

- (NSDictionary *)_entitlementsForBundleIdentifier:(NSString *)bundleIdentifier
                                            profile:(NSDictionary *)profile
                                         mainBundle:(BOOL)mainBundle {
    NSString *group = RBXAppKeychainGroup(self.appDescriptor, bundleIdentifier);
    NSArray *groups = RBXAppKeychainGroups(self.appDescriptor, bundleIdentifier);
    if (!group || !groups.count) return nil;
    NSMutableDictionary *entitlements = [@{
        @"application-identifier": group,
        @"com.apple.developer.team-identifier": self.appDescriptor[@"teamIdentifier"],
        @"keychain-access-groups": groups,
    } mutableCopy];
    if (mainBundle &&
        [profile[@"security"][@"appAttest"] isEqualToString:@"enabled"]) {
        entitlements[@"com.apple.developer.devicecheck.appattest-environment"] =
            @"production";
    }
    return entitlements;
}

- (BOOL)_rewriteAndSignBundle:(NSString *)bundlePath
             bundleIdentifier:(NSString *)bundleIdentifier
                     nickname:(NSString *)nickname
                      profile:(NSDictionary *)profile
                        error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    if (RBXAppKeychainMappingEnabled(self.appDescriptor) &&
        (RBXAppProfileIdentityBlockReason(self.appDescriptor, profile, profile[@"containerId"]) ||
         ![bundleIdentifier isEqual:RBXAppBundleIdentifier(self.appDescriptor, profile[@"containerId"])] ||
         !RBXAppKeychainMetadataMatches(self.appDescriptor, bundleIdentifier, profile[@"app"]))) {
        if (error) *error = RBXCloneError(26, @"complete app-scoped Keychain bootstrap is required before signing");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *component in @[@"PlugIns", @"Watch", @"AppClips"]) {
        if (!RBXCloneMayMutate(error)) return NO;
        [fm removeItemAtPath:[bundlePath stringByAppendingPathComponent:component]
                       error:nil];
    }

    NSMutableArray<NSString *> *removePaths = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bundlePath];
    for (NSString *relative in enumerator) {
        if (!RBXCloneMayMutate(error)) return NO;
        if ([relative.lastPathComponent isEqualToString:@"embedded.mobileprovision"] ||
            [relative.lastPathComponent isEqualToString:@"_CodeSignature"] ||
            [relative.pathExtension.lowercaseString isEqualToString:@"provisionprofile"]) {
            [removePaths addObject:[bundlePath stringByAppendingPathComponent:relative]];
            if ([relative.lastPathComponent isEqualToString:@"_CodeSignature"]) {
                [enumerator skipDescendants];
            }
        }
    }
    for (NSString *path in removePaths.reverseObjectEnumerator) {
        if (!RBXCloneMayMutate(error)) return NO;
        [fm removeItemAtPath:path error:nil];
    }

    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *info =
        [[NSDictionary dictionaryWithContentsOfFile:infoPath] mutableCopy];
    NSString *executableName = info[@"CFBundleExecutable"];
    NSString *mainBinary = [bundlePath stringByAppendingPathComponent:executableName ?: @""];
    if (!info || ![fm isExecutableFileAtPath:mainBinary]) {
        if (error) *error = RBXCloneError(12, @"clone main bundle is incomplete");
        return NO;
    }
    if (!RBXRewriteAppKeychainInfo(info, self.appDescriptor, bundleIdentifier, error)) return NO;
    info[@"CFBundleIdentifier"] = bundleIdentifier;
    info[@"CFBundleDisplayName"] = nickname.length ? nickname :
        [NSString stringWithFormat:@"%@ %@", self.appDescriptor[@"displayName"], profile[@"containerId"] ?: @""];
    info[@"CFBundleName"] = info[@"CFBundleDisplayName"];
    // SpringBoard honors the private "hidden" app tag while LaunchServices can
    // still launch the bundle by identifier. The daemon validates this signed
    // bundle metadata before it will grant a network lease.
    info[@"SBAppTags"] = @[@"hidden"];
    [info removeObjectForKey:@"SBIconVisibilityDefaultVisible"];
    info[@"RBXLauncherOnly"] = @YES;

    // Keep Reddit's registered callback for compatibility, but also register a
    // deterministic clone-specific scheme for diagnostics and future callback
    // migration. OAuth using the shared scheme remains an explicit device test.
    NSMutableArray *urlTypes = [info[@"CFBundleURLTypes"] mutableCopy]
        ?: [NSMutableArray array];
    NSString *diagnosticScheme = [@"reddit-" stringByAppendingString:
        bundleIdentifier.lastPathComponent.lowercaseString];
    [urlTypes addObject:@{
        @"CFBundleURLName": [bundleIdentifier stringByAppendingString:@".callback"],
        @"CFBundleURLSchemes": @[diagnosticScheme],
    }];
    info[@"CFBundleURLTypes"] = urlTypes;
    if (![info writeToFile:infoPath atomically:YES]) {
        if (error) *error = RBXCloneError(13, @"cannot rewrite clone Info.plist");
        return NO;
    }

    NSMutableDictionary *cloneMetadata = [@{
        @"formatVersion": RBXAppKeychainMappingEnabled(self.appDescriptor) ? @2 : @1,
        @"sourceBundleIdentifier": (self.appDescriptor[@"sourceBundleIdentifier"]),
        @"bundleIdentifier": bundleIdentifier,
        @"containerId": profile[@"containerId"] ?: @"",
        @"keychainAccessGroup": RBXAppKeychainGroup(self.appDescriptor, bundleIdentifier),
        @"appAttestEntitled": @([profile[@"security"][@"appAttest"]
            isEqualToString:@"enabled"]),
        @"diagnosticURLScheme": diagnosticScheme,
        @"installer": @"appinst",
        @"launcherOnly": @YES,
        @"flowSigningIdentifier": bundleIdentifier,
        @"installationTransaction": profile[@"installationTransaction"] ?: @"",
        @"sourceVersion": profile[@"app"][@"sourceVersion"] ?: @"",
        @"sourceBuild": profile[@"app"][@"sourceBuild"] ?: @"",
    } mutableCopy];
    [cloneMetadata addEntriesFromDictionary:RBXAppKeychainMetadata(self.appDescriptor, bundleIdentifier)];
    if (RBXAppKeychainMappingEnabled(self.appDescriptor)) cloneMetadata[@"appType"] = self.appDescriptor[@"appType"];
    if (![cloneMetadata writeToFile:[bundlePath stringByAppendingPathComponent:
        @".redditbox-clone.plist"] atomically:YES]) {
        if (error) *error = RBXCloneError(41, @"cannot persist clone transaction identity");
        return NO;
    }
    NSData *bootstrap = [NSJSONSerialization dataWithJSONObject:RBXProfileForTransport(profile)
        options:NSJSONWritingPrettyPrinted error:nil];
    NSString *bootstrapPath = [bundlePath stringByAppendingPathComponent:@"RedditBoxProfile.json"];
    if (![bootstrap writeToFile:bootstrapPath options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    if (chmod(bootstrapPath.fileSystemRepresentation, 0600) != 0 ||
        chown(bootstrapPath.fileSystemRepresentation, 501, 501) != 0) {
        if (error) *error = RBXCloneError(41, @"bootstrap profile permissions could not be restricted"); return NO;
    }

    NSString *ldid = RBXExecutable(@"ldid");
    if (!ldid.length) {
        if (error) *error = RBXCloneError(11, @"ldid is required to sign cloned apps");
        return NO;
    }

    NSString *entitlementsPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"redditbox-entitlements-%@.plist", NSUUID.UUID.UUIDString]];
    NSString *emptyEntitlementsPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"redditbox-empty-entitlements-%@.plist", NSUUID.UUID.UUIDString]];
    NSDictionary *entitlements = [self _entitlementsForBundleIdentifier:bundleIdentifier
        profile:profile mainBundle:YES];
    if (![entitlements writeToFile:entitlementsPath atomically:YES] ||
        ![@{} writeToFile:emptyEntitlementsPath atomically:YES]) {
        if (error) *error = RBXCloneError(15, @"cannot create clone entitlements");
        return NO;
    }

    NSMutableArray<NSString *> *nestedMachO = [NSMutableArray array];
    enumerator = [fm enumeratorAtPath:bundlePath];
    for (NSString *relative in enumerator) {
        if (!RBXCloneMayMutate(error)) return NO;
        NSString *path = [bundlePath stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        if (![fm fileExistsAtPath:path isDirectory:&directory] || directory ||
            [path isEqualToString:mainBinary]) continue;
        if (RBXIsMachOAtPath(path)) [nestedMachO addObject:path];
    }
    [nestedMachO sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSUInteger leftDepth = left.pathComponents.count;
        NSUInteger rightDepth = right.pathComponents.count;
        if (leftDepth != rightDepth) {
            return leftDepth > rightDepth ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left compare:right];
    }];
    for (NSString *binary in nestedMachO) {
        if (!RBXCloneMayMutate(error)) return NO;
        if (!RBXSpawnAndWait(ldid,
            @[[@"-S" stringByAppendingString:emptyEntitlementsPath], binary], error)) {
            if (RBXCloneContinue(nil)) [fm removeItemAtPath:entitlementsPath error:nil];
            if (RBXCloneContinue(nil)) [fm removeItemAtPath:emptyEntitlementsPath error:nil];
            if (error) *error = RBXCloneError(16,
                [NSString stringWithFormat:@"ldid failed for nested code %@", binary.lastPathComponent]);
            return NO;
        }
    }
    BOOL mainStatus = RBXSpawnAndWait(ldid,
        @[[@"-S" stringByAppendingString:entitlementsPath],
          [@"-I" stringByAppendingString:bundleIdentifier], mainBinary], error);
    if (RBXCloneContinue(nil)) [fm removeItemAtPath:emptyEntitlementsPath error:nil];
    if (!mainStatus) {
        if (RBXCloneContinue(nil)) [fm removeItemAtPath:entitlementsPath error:nil];
        if (error) *error = RBXCloneError(16, @"ldid failed for clone main executable");
        return NO;
    }

    NSString *effectivePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"redditbox-effective-%@.plist", NSUUID.UUID.UUIDString]];
    BOOL inspectStatus = RBXSpawnCapturingStdout(ldid, @[@"-e", mainBinary], effectivePath, error);
    NSDictionary *effective = inspectStatus
        ? [NSDictionary dictionaryWithContentsOfFile:effectivePath] : nil;
    if (RBXCloneContinue(nil)) [fm removeItemAtPath:effectivePath error:nil];
    if (RBXCloneContinue(nil)) [fm removeItemAtPath:entitlementsPath error:nil];
    NSString *expectedGroup =
        RBXAppKeychainGroup(self.appDescriptor, bundleIdentifier);
    NSArray *groups = effective[@"keychain-access-groups"];
    BOOL attestExpected =
        [profile[@"security"][@"appAttest"] isEqualToString:@"enabled"];
    BOOL effectiveValid =
        [effective[@"application-identifier"] isEqualToString:expectedGroup] &&
        [effective[@"com.apple.developer.team-identifier"] isEqual:self.appDescriptor[@"teamIdentifier"]] &&
        [groups isEqual:RBXAppKeychainGroups(self.appDescriptor, bundleIdentifier)] &&
        effective[@"com.apple.security.application-groups"] == nil &&
        effective[@"aps-environment"] == nil &&
        effective[@"com.apple.developer.ubiquity-container-identifiers"] == nil &&
        effective[@"com.apple.developer.ubiquity-kvstore-identifier"] == nil &&
        effective[@"com.apple.developer.icloud-container-identifiers"] == nil &&
        effective[@"com.apple.developer.icloud-services"] == nil &&
        effective[@"com.apple.developer.associated-domains"] == nil &&
        effective[@"get-task-allow"] == nil &&
        (attestExpected
            ? [effective[@"com.apple.developer.devicecheck.appattest-environment"]
                isEqualToString:@"production"]
            : effective[@"com.apple.developer.devicecheck.appattest-environment"] == nil);
    if (!effectiveValid) {
        if (error) *error = RBXCloneError(26,
            @"effective clone entitlements do not match the isolated policy");
        return NO;
    }
    return YES;
}

- (BOOL)_archiveTransactionRoot:(NSString *)root
                         output:(NSString *)output
                          error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *zip = RBXExecutable(@"zip");
    NSString *shell = RBXExecutable(@"sh");
    if (!zip.length || !shell.length) {
        if (error) *error = RBXCloneError(17, @"zip and sh are required to build clone IPAs");
        return NO;
    }
    NSString *command = [NSString stringWithFormat:@"cd %@ && %@ -qry %@ Payload",
        RBXShellQuote(root), RBXShellQuote(zip), RBXShellQuote(output)];
    if (!RBXSpawnAndWait(shell, @[@"-c", command], error)) {
        if (error) *error = RBXCloneError(18, @"cannot package staged clone IPA");
        return NO;
    }
    return YES;
}

- (BOOL)_installIPA:(NSString *)ipa error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *appinst = RBXExecutable(@"appinst");
    if (!appinst.length) {
        if (error) *error = RBXCloneError(27,
            @"appinst is required; direct /Applications registration is forbidden");
        return NO;
    }
    int directory = RBXOpenInstallerEvidence(ipa, self.appDescriptor, error);
    if (directory < 0) return NO;
    NSString *name = [@"installer-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *output = [ipa.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:@"stdout"]];
    @try {
        NSError *installError = nil;
        BOOL installed = [RBXBoundedProcess runExecutable:appinst arguments:@[ipa]
            context:RBXOperationContext.currentContext outputPath:output maximumOutputBytes:65536 error:&installError];
        // This private evidence is written through the verified directory even
        // after cancellation, before the existing service-uncertainty fence.
        RBXFinishInstallerEvidence(directory, name, installError, installed);
        if (!installed) {
            if (![@NO isEqual:installError.userInfo[@"childStarted"]])
                [RBXOperationContext.currentContext markUnsafeWithReason:@"Installer failure left service-side installation completion unproven; transaction backups are retained" error:nil];
            if (error) *error = installError ?: RBXCloneError(28, @"installd/AppSync rejected the clone IPA");
            return NO;
        }
        return YES;
    } @finally {
        close(directory);
    }
}

- (BOOL)_uninstallBundleIdentifier:(NSString *)bundleIdentifier
                expectedBundlePath:(NSString *)bundlePath error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    if (!RBXRemovalIdentifierAllowed(bundleIdentifier) ||
        ![RBXAppDescriptorForBundleIdentifier(bundleIdentifier) isEqual:self.appDescriptor] ||
        (bundlePath && (![bundlePath isKindOfClass:NSString.class] || !bundlePath.isAbsolutePath))) {
        if (error) *error = RBXCloneError(73, @"uninstall is restricted to this app's source and verified clones"); return NO;
    }
    NSDictionary *registration = RBXInstalledApplication(bundleIdentifier, error);
    if (!registration) return NO;
    NSString *evidenceRoot = [[RBXTransactionsRoot stringByAppendingPathComponent:@"uninstall-evidence"]
        stringByAppendingPathComponent:bundleIdentifier];
    NSString *evidencePath = [evidenceRoot stringByAppendingPathComponent:@"transaction.plist"];
    NSFileManager *fm = NSFileManager.defaultManager;
    struct stat evidenceStat;
    NSMutableDictionary *capture = nil;
    if (lstat(evidencePath.fileSystemRepresentation, &evidenceStat) == 0) {
        if (!S_ISREG(evidenceStat.st_mode) || evidenceStat.st_uid != 0 || (evidenceStat.st_mode & 0022)) {
            if (error) *error = RBXCloneError(73, @"uninstall evidence has an invalid owner or file type"); return NO;
        }
        capture = [[NSDictionary dictionaryWithContentsOfFile:evidencePath] mutableCopy];
        if (![capture[@"bundleIdentifier"] isEqual:bundleIdentifier] || ![capture[@"formatVersion"] isKindOfClass:NSNumber.class] || [capture[@"formatVersion"] integerValue] != 1 ||
            ![capture[@"paths"] isKindOfClass:NSArray.class] || ![capture[@"paths"] count] ||
            ![capture[@"pluginIDs"] isKindOfClass:NSArray.class] ||
            ![capture[@"bundlePath"] isKindOfClass:NSString.class] ||
            ![capture[@"dataPath"] isKindOfClass:NSString.class] ||
            ![capture[@"bundleDevice"] isKindOfClass:NSNumber.class] ||
            ![capture[@"bundleInode"] isKindOfClass:NSNumber.class] ||
            ![capture[@"dataDevice"] isKindOfClass:NSNumber.class] ||
            ![capture[@"dataInode"] isKindOfClass:NSNumber.class] ||
            ![capture[@"installationTransaction"] isKindOfClass:NSString.class]) {
            if (error) *error = RBXCloneError(73, @"uninstall evidence is invalid; retain it for recovery"); return NO;
        }
        for (id path in capture[@"paths"]) {
            if (!RBXCloneMayMutate(error)) return NO;
            if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) {
                if (error) *error = RBXCloneError(73, @"uninstall evidence contains an invalid path"); return NO;
            }
        }
        for (id identifier in capture[@"pluginIDs"]) {
            if (!RBXCloneMayMutate(error)) return NO;
            if (![identifier isKindOfClass:NSString.class] ||
                ![identifier hasPrefix:[bundleIdentifier stringByAppendingString:@"."]]) {
                if (error) *error = RBXCloneError(73, @"uninstall evidence contains an invalid plugin identity"); return NO;
            }
        }
    } else if (errno != ENOENT) {
        if (error) *error = RBXCloneError(73, @"cannot read retained uninstall evidence"); return NO;
    }
    id proxy = registration[@"proxy"];
    if (proxy) {
        if (capture) {
            NSString *currentBundle = nil;
            @try {
                currentBundle = RBXProxyPath(proxy, @"bundleURL", error);
                NSString *currentData = RBXProxyPath(proxy, @"dataContainerURL", error);
                if (!currentData || ![currentData isEqual:capture[@"dataPath"]]) {
                    if (error && !*error) *error = RBXCloneError(73, @"app data container changed during pending uninstall"); return NO;
                }
                for (NSString *kind in @[@"bundle", @"data"]) {
                    if (!RBXCloneMayMutate(error)) return NO;
                    NSString *path = [kind isEqualToString:@"bundle"] ? currentBundle : currentData;
                    struct stat currentStat;
                    if (lstat(path.fileSystemRepresentation, &currentStat) == 0) {
                        if (!S_ISDIR(currentStat.st_mode) ||
                            currentStat.st_dev != [capture[[kind stringByAppendingString:@"Device"]] unsignedLongLongValue] ||
                            currentStat.st_ino != [capture[[kind stringByAppendingString:@"Inode"]] unsignedLongLongValue]) {
                            if (error) *error = RBXCloneError(73, @"installation identity changed while uninstall evidence was pending"); return NO;
                        }
                        if ([kind isEqualToString:@"bundle"]) {
                            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
                            NSDictionary *marker = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@".redditbox-clone.plist"]];
                            NSString *transaction = [marker[@"installationTransaction"] isKindOfClass:NSString.class] ? marker[@"installationTransaction"] : @"";
                            if (![bundleIdentifier isEqual:info[@"CFBundleIdentifier"]] ||
                                ![capture[@"installationTransaction"] isEqual:transaction]) {
                                if (error) *error = RBXCloneError(73, @"a newer or unknown installation occupies the pending uninstall target"); return NO;
                            }
                        }
                    } else if (errno != ENOENT) {
                        if (error) *error = RBXCloneError(73, @"cannot verify identity of a pending uninstall target"); return NO;
                    }
                }
                SEL pluginsSelector = NSSelectorFromString(@"plugInKitPlugins");
                id plugins = [proxy respondsToSelector:pluginsSelector] ? ((id (*)(id, SEL))objc_msgSend)(proxy, pluginsSelector) : nil;
                if (![plugins isKindOfClass:NSArray.class]) {
                    if (error) *error = RBXCloneError(73, @"cannot verify pending uninstall plugins"); return NO;
                }
                for (id plugin in plugins) {
                    if (!RBXCloneMayMutate(error)) return NO;
                    NSString *pluginBundle = RBXProxyPath(plugin, @"bundleURL", error);
                    NSString *pluginData = RBXProxyPath(plugin, @"dataContainerURL", error);
                    if (!pluginBundle || !pluginData || ![capture[@"paths"] containsObject:pluginBundle] ||
                        ![capture[@"paths"] containsObject:pluginData]) {
                        if (error && !*error) *error = RBXCloneError(73, @"plugin containers changed during pending uninstall"); return NO;
                    }
                }
            }
            @catch (NSException *exception) {
                if (error) *error = RBXCloneError(73, @"cannot verify pending uninstall registration"); return NO;
            }
            if (!currentBundle) return NO;
            if (![capture[@"bundlePath"] isEqual:currentBundle] ||
                (bundlePath.length && ![currentBundle isEqualToString:bundlePath.stringByResolvingSymlinksInPath])) {
                if (error) *error = RBXCloneError(73, @"app bundle changed while uninstall evidence was pending; recovery retained"); return NO;
            }
        } else {
            NSDictionary *current = RBXCaptureRemoval(proxy, bundleIdentifier, bundlePath, error);
            if (!current) return NO;
            capture = [current mutableCopy];
            capture[@"bundleIdentifier"] = bundleIdentifier;
            capture[@"formatVersion"] = @1;
            if (![fm createDirectoryAtPath:evidenceRoot withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0700} error:error] ||
                !RBXWriteJournal(evidenceRoot, capture, @"captured", error)) return NO;
        }
    } else if (!capture) {
        // There was no side effect in this attempt. A stale profile's known
        // bundle must also be absent before an already-uninstalled reply.
        BOOL absent = YES;
        if (bundlePath.length && (!RBXRemovalPathsAbsent(@[bundlePath], &absent, error) || !absent)) {
            if (error && !*error) *error = RBXCloneError(73, @"unregistered app bundle still exists; manual recovery is required"); return NO;
        }
        // Container metadata supplies ownership when no proxy or prior capture
        // remains. Never erase these paths manually or call the state clean.
        for (NSString *root in @[@"/var/mobile/Containers/Data/Application", @"/var/containers/Data/Application",
            @"/var/mobile/Containers/Data/PluginKitPlugin", @"/var/containers/Data/PluginKitPlugin"]) {
            NSError *listingError = nil;
            NSArray *entries = [fm contentsOfDirectoryAtPath:root error:&listingError];
            if (!entries) {
                struct stat unused;
                if (lstat(root.fileSystemRepresentation, &unused) < 0 && errno == ENOENT) continue;
                if (error) *error = listingError ?: RBXCloneError(73, @"cannot prove container absence"); return NO;
            }
            for (NSString *entry in entries) {
                if (!RBXCloneMayMutate(error)) return NO;
                if (![[NSUUID alloc] initWithUUIDString:entry]) continue;
                NSString *metadataPath = [[root stringByAppendingPathComponent:entry]
                    stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
                NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                id owner = metadata[@"MCMMetadataIdentifier"];
                if (![owner isKindOfClass:NSString.class]) {
                    if (error) *error = RBXCloneError(73, @"cannot identify a container while proving uninstall absence"); return NO;
                }
                if ([owner isEqualToString:bundleIdentifier] || [owner hasPrefix:[bundleIdentifier stringByAppendingString:@"."]]) {
                    if (error) *error = RBXCloneError(73, @"unregistered app or plugin data remains; recovery is required"); return NO;
                }
            }
        }
        return YES;
    }
    id workspace = registration[@"workspace"];
    NSArray *pluginIDs = capture[@"pluginIDs"];
    SEL pluginsSelector = NSSelectorFromString(@"pluginsWithIdentifiers:protocols:version:");
    SEL uninstall = NSSelectorFromString(@"uninstallApplication:withOptions:");
    if ((pluginIDs.count && ![workspace respondsToSelector:pluginsSelector]) ||
        (proxy && ![workspace respondsToSelector:uninstall])) {
        if (error) *error = RBXCloneError(74, @"this iOS build does not expose a verifiable app uninstall service"); return NO;
    }
    struct timespec started;
    if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
        if (error) *error = RBXCloneError(74, @"cannot measure the uninstall verification deadline"); return NO;
    }
    return [RBXStorageAccess performInstallerMaintenanceForBundle:bundleIdentifier
        expectedBundlePath:capture[@"bundlePath"] operation:^BOOL(NSError **error) {
    @try {
        if (proxy && !((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace, uninstall, bundleIdentifier, nil)) {
            if (error) *error = RBXCloneError(74, @"LaunchServices rejected the uninstall; captured recovery evidence is retained"); return NO;
        }
        for (;;) {
            if (!RBXCloneMayMutate(error)) return NO;
            NSDictionary *current = RBXInstalledApplication(bundleIdentifier, error);
            if (!current) return NO;
            BOOL pathsAbsent = NO;
            if (!RBXRemovalPathsAbsent(capture[@"paths"], &pathsAbsent, error)) return NO;
            BOOL pluginsAbsent = YES;
            if (pluginIDs.count) {
                id registeredPlugins = ((id (*)(id, SEL, id, id, id))objc_msgSend)(current[@"workspace"], pluginsSelector, pluginIDs, @[], nil);
                if (![registeredPlugins isKindOfClass:NSArray.class]) {
                    if (error) *error = RBXCloneError(74, @"cannot verify plugin registration removal"); return NO;
                }
                pluginsAbsent = [registeredPlugins count] == 0;
            }
            if (!current[@"proxy"] && pathsAbsent && pluginsAbsent) return [fm removeItemAtPath:evidenceRoot error:error];
            struct timespec now;
            if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 ||
                (now.tv_sec - started.tv_sec) + (now.tv_nsec - started.tv_nsec) / 1e9 >= 10.0) break;
            [NSThread sleepForTimeInterval:0.1];
        }
    } @catch (NSException *exception) {
        if (error) *error = RBXCloneError(74, @"LaunchServices uninstall failed; captured recovery evidence is retained"); return NO;
    }
    [RBXOperationContext.currentContext markUnsafeWithReason:@"Uninstall verification expired with service-side work unproven" error:nil];
    if (error) *error = RBXCloneError(74, @"uninstall did not remove every registration and captured app/plugin path; recovery evidence is retained");
    return NO;
    } error:error];
}

- (unsigned long long)_logicalSizeOfTree:(NSString *)path {
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:path]
        includingPropertiesForKeys:@[NSURLFileSizeKey]
        options:0 errorHandler:nil];
    for (NSURL *url in enumerator) {
        if (!RBXCloneContinue(nil)) return 0;
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

- (NSDictionary *)_operation_ensureCloneForContainer:(NSString *)containerId
                                  profile:(NSDictionary *)profile
                                 nickname:(NSString *)nickname
                                    error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return nil;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return nil;
    NSDictionary *result=nil;
    @try { result=[self _ensureCloneForContainer:containerId profile:profile nickname:nickname error:error]; }
    @finally {
        NSError *sealError=nil;
        if(![RBXStorageAccess closeAll:&sealError]){result=nil;if(error)*error=sealError;}
        flock(fd, LOCK_UN); close(fd);
    }
    return result;
}

- (NSDictionary *)_ensureCloneForContainer:(NSString *)containerId
                                  profile:(NSDictionary *)profile
                                 nickname:(NSString *)nickname
                                    error:(NSError **)error {
    if (!RBXContainerAvailable(containerId, error)) return nil;
    NSString *bundleIdentifier = RBXAppBundleIdentifier(self.appDescriptor, containerId);
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:RBXTransactionsRoot error:nil]) {
        NSString *root = [RBXTransactionsRoot stringByAppendingPathComponent:entry];
        NSString *path = [root stringByAppendingPathComponent:@"transaction.plist"];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:path];
        NSDictionary *pendingOwner = RBXAppInstallationRecordDescriptor(pending);
        if (!pendingOwner || ([pending[@"containerId"] isEqual:containerId] && ![pendingOwner isEqual:self.appDescriptor])) {
            if (error) *error = RBXCloneError(35, @"pending installation has an unknown or conflicting app identity"); return nil;
        }
        if ([pending[@"bundleIdentifier"] isEqualToString:bundleIdentifier]) {
            if (![self _recoverTransaction:root error:error]) return nil;
        }
    }
    if (!RBXNoPendingRemoval(bundleIdentifier, error)) return nil;
    NSString *destination = [self _installedBundleForIdentifier:bundleIdentifier];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:
        [destination stringByAppendingPathComponent:@".redditbox-clone.plist"]];
    NSDictionary *existingInfo = [NSDictionary dictionaryWithContentsOfFile:
        [destination stringByAppendingPathComponent:@"Info.plist"]];
    BOOL existingBundleShapeValid =
        [existingInfo[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier] &&
        [existingInfo[@"SBAppTags"] containsObject:@"hidden"] &&
        [existingInfo[@"RBXLauncherOnly"] boolValue] &&
        [NSFileManager.defaultManager fileExistsAtPath:
            [destination stringByAppendingPathComponent:@"RedditBoxProfile.json"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:
            [destination stringByAppendingPathComponent:@"embedded.mobileprovision"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:
            [destination stringByAppendingPathComponent:@"PlugIns"]] &&
        [existing[@"installer"] isEqualToString:@"appinst"] &&
        [existing[@"launcherOnly"] boolValue] &&
        [existing[@"flowSigningIdentifier"] isEqualToString:bundleIdentifier] &&
        RBXAppKeychainMarkerMatches(self.appDescriptor, bundleIdentifier, existing);
    BOOL wantsAttest =
        [profile[@"security"][@"appAttest"] isEqualToString:@"enabled"];
    NSString *exportedIPA = nil;
    NSString *availableSource = [self _sourceRedditBundle];
    NSDictionary *availableSourceInfo = availableSource.length
        ? [NSDictionary dictionaryWithContentsOfFile:
            [availableSource stringByAppendingPathComponent:@"Info.plist"]] : nil;
    NSString *sourceVersion = availableSourceInfo[@"CFBundleShortVersionString"] ?: @"";
    NSString *sourceBuild = availableSourceInfo[@"CFBundleVersion"] ?: @"";
    BOOL sourceDrift = availableSource.length && existingBundleShapeValid &&
        (![existing[@"sourceVersion"] isEqualToString:sourceVersion] ||
         ![existing[@"sourceBuild"] isEqualToString:sourceBuild]);
    if (!existingBundleShapeValid || !RBXBootstrapIsRedacted(destination) ||
        !RBXBootstrapMatchesIdentity(destination, profile) ||
        ![existing[@"containerId"] isEqualToString:containerId] ||
        ![existing[@"bundleIdentifier"] isEqualToString:bundleIdentifier] ||
        [existing[@"appAttestEntitled"] boolValue] !=
            wantsAttest || sourceDrift) {
        NSString *source = availableSource;
        if (!source.length) {
            if (error) *error = RBXCloneError(19, [NSString stringWithFormat:@"original %@ app is not installed", self.appDescriptor[@"sourceBundleIdentifier"]]);
            return nil;
        }
        NSDictionary *sourceInfo = [NSDictionary dictionaryWithContentsOfFile:
            [source stringByAppendingPathComponent:@"Info.plist"]];
        NSString *sourceBinary = [source stringByAppendingPathComponent:
            sourceInfo[@"CFBundleExecutable"] ?: @""];
        if (RBXMachOIsEncryptedAtPath(sourceBinary)) {
            if (error) *error = RBXCloneError(24,
                @"source Reddit binary is encrypted or invalid; install a decrypted IPA before cloning");
            return nil;
        }
        NSString *transactionRoot = [RBXTransactionsRoot
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        if (![[[RBXProcessController alloc] initWithAppDescriptor:self.appDescriptor] killAllAndWait:8.0]) {
            if (error) *error = RBXCloneError(42, @"cannot quiesce clone processes before data snapshot");
            return nil;
        }
        NSString *payload = [transactionRoot stringByAppendingPathComponent:@"Payload"];
        NSString *stagedBundle = [payload stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]];
        [NSFileManager.defaultManager createDirectoryAtPath:payload
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSError *operationError = nil;
        NSMutableDictionary *journal = [RBXAppInstallationRecord(self.appDescriptor, containerId) mutableCopy];
        if (!journal) { if (error) *error = RBXCloneError(35, @"invalid installation identity"); return nil; }
        // C comparisons box as NSNumber integers in .m files. Facebook's
        // versioned recovery contract requires an actual CFBoolean.
        journal[@"hadPreviousInstall"] = RBXAppKeychainMappingEnabled(self.appDescriptor)
            ? (destination.length ? @YES : @NO) : @(destination.length > 0);
        if (!RBXWriteJournal(transactionRoot, journal, @"prepared", &operationError)) {
            if (RBXCloneContinue(nil)) [NSFileManager.defaultManager removeItemAtPath:transactionRoot error:nil];
            if (error) *error = operationError;
            return nil;
        }
        NSDictionary *filesystem = [NSFileManager.defaultManager
            attributesOfFileSystemForPath:@"/var/mobile" error:nil];
        unsigned long long freeBytes = [filesystem[NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long sourceBytes = [self _logicalSizeOfTree:source];
        NSString *previousData = destination.length
            ? [self dataContainerForBundleIdentifier:bundleIdentifier] : nil;
        unsigned long long requiredBytes =
            MAX(1536ULL * 1024ULL * 1024ULL, sourceBytes * (destination.length ? 4 : 3)) +
            (previousData.length ? 2 * [self _logicalSizeOfTree:previousData] : 0);
        if (!RBXCloneMayMutate(error)) return nil;
        if (freeBytes < requiredBytes) {
            if (RBXCloneContinue(nil)) [NSFileManager.defaultManager removeItemAtPath:transactionRoot error:nil];
            if (error) *error = RBXCloneError(25,
                @"insufficient free space for staged IPA install and rollback");
            return nil;
        }

        NSMutableDictionary *provisionalApp = [@{
            @"architecture": @"clonedApp-v2",
            @"sourceBundleIdentifier": (self.appDescriptor[@"sourceBundleIdentifier"]),
            @"bundleIdentifier": bundleIdentifier,
            @"bundlePath": @"",
            @"keychainAccessGroup":
                RBXAppKeychainGroup(self.appDescriptor, bundleIdentifier),
            @"cloneState": @"installing",
            @"appAttestEntitled": @(wantsAttest),
            @"sourceVersion": sourceVersion,
            @"sourceBuild": sourceBuild,
        } mutableCopy];
        [provisionalApp addEntriesFromDictionary:RBXAppKeychainMetadata(self.appDescriptor, bundleIdentifier)];
        NSMutableDictionary *bootstrapProfile = [profile mutableCopy];
        bootstrapProfile[@"app"] = provisionalApp;
        bootstrapProfile[@"installationTransaction"] = transactionRoot.lastPathComponent;

        NSString *backupRoot = [transactionRoot stringByAppendingPathComponent:@"backup"];
        NSString *backupIPA = [transactionRoot stringByAppendingPathComponent:@"previous.ipa"];
        BOOL backupReady = NO;
        if (destination.length) {
            NSString *backupPayload = [backupRoot stringByAppendingPathComponent:@"Payload"];
            NSString *backupBundle = [backupPayload stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]];
            [NSFileManager.defaultManager createDirectoryAtPath:backupPayload
                withIntermediateDirectories:YES attributes:nil error:nil];
            backupReady =
                previousData.length &&
                [self _snapshotData:previousData toPath:[transactionRoot
                    stringByAppendingPathComponent:@"previous-data"] error:&operationError] &&
                [self _copyBundleAtPath:destination toPath:backupBundle error:&operationError] &&
                RBXPrepareStagedExecutable(backupBundle,RBXTransactionsRoot,0,0,&operationError) &&
                [self _archiveTransactionRoot:backupRoot output:backupIPA error:&operationError];
            if (!backupReady) {
                if (RBXCloneContinue(nil)) [NSFileManager.defaultManager removeItemAtPath:transactionRoot error:nil];
                if (error) *error = operationError ?: RBXCloneError(29,
                    @"cannot create rollback IPA for existing clone");
                return nil;
            }
        }

        NSString *newIPA = [transactionRoot stringByAppendingPathComponent:@"clone.ipa"];
        BOOL staged =
            [self _copyBundleAtPath:source toPath:stagedBundle error:&operationError] &&
            [self _rewriteAndSignBundle:stagedBundle bundleIdentifier:bundleIdentifier
                nickname:nickname profile:bootstrapProfile error:&operationError] &&
            [self _archiveTransactionRoot:transactionRoot output:newIPA error:&operationError];
        BOOL journalReady = staged &&
            RBXWriteJournal(transactionRoot, journal, @"install-attempted", &operationError);
        BOOL installed = journalReady && [self _installIPA:newIPA error:&operationError];
        if (staged && !journalReady) {
            operationError = RBXCloneError(32, @"cannot persist clone transaction journal");
        }
        NSString *installedPath = nil;
        if (installed) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
            do {
                if (!RBXCloneMayMutate(&operationError)) { installed = NO; break; }
                installedPath = [self _installedBundleForIdentifier:bundleIdentifier];
                if (installedPath.length &&
                    [self dataContainerForBundleIdentifier:bundleIdentifier].length) break;
                [NSThread sleepForTimeInterval:0.1];
            } while (deadline.timeIntervalSinceNow > 0);
            installed = installed && RBXCloneMayMutate(&operationError) && installedPath.length &&
                [self dataContainerForBundleIdentifier:bundleIdentifier].length;
            NSDictionary *installedMarker = installedPath.length ?
                [NSDictionary dictionaryWithContentsOfFile:[installedPath
                    stringByAppendingPathComponent:@".redditbox-clone.plist"]] : nil;
            installed = installed && [installedMarker[@"installationTransaction"]
                isEqualToString:transactionRoot.lastPathComponent];
            if (!installed) operationError = RBXCloneError(30,
                @"installd did not allocate both bundle and data containers");
        }
        if (installed) installed = RBXWriteJournal(transactionRoot, journal, @"installed", &operationError);
        if (!installed) {
            if (!RBXCloneMayMutate(error)) return nil;
            NSError *recoveryError = nil;
            [self _recoverTransaction:transactionRoot error:&recoveryError];
            if (error) *error = recoveryError ?: operationError;
            return nil;
        }
        destination = installedPath;
        // Legacy files are retained; deleting them before commit can destroy the
        // only previous installation. Cleanup is separate from this transaction.
        const char *keepIPA = getenv("RBX_KEEP_CLONE_IPA");
        if (keepIPA && strcmp(keepIPA, "1") == 0) {
            NSString *exports = @"/var/mobile/Library/RedditBox/IPAs";
            [NSFileManager.defaultManager createDirectoryAtPath:exports
                withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0700} error:nil];
            exportedIPA = [exports stringByAppendingPathComponent:
                [bundleIdentifier stringByAppendingPathExtension:@"ipa"]];
            [NSFileManager.defaultManager removeItemAtPath:exportedIPA error:nil];
            if (![NSFileManager.defaultManager copyItemAtPath:newIPA
                toPath:exportedIPA error:&operationError]) {
                NSError *recoveryError = nil;
                [self _recoverTransaction:transactionRoot error:&recoveryError];
                if (error) *error = recoveryError ?: operationError;
                return nil;
            }
            chmod(exportedIPA.fileSystemRepresentation, 0600);
        }
        if (!RBXWriteJournal(transactionRoot, journal, @"committed", &operationError)) {
            // An installed journal remains recoverable. Never discard its backup.
            if (error) *error = operationError;
            return nil;
        }
        if (RBXCloneContinue(nil)) [NSFileManager.defaultManager removeItemAtPath:transactionRoot error:nil];
    }
    const char *keepIPA = getenv("RBX_KEEP_CLONE_IPA");
    if (!exportedIPA.length && keepIPA && strcmp(keepIPA, "1") == 0 &&
        destination.length) {
        NSString *exportRoot = [RBXTransactionsRoot stringByAppendingPathComponent:
            NSUUID.UUID.UUIDString];
        NSString *exportPayload = [exportRoot stringByAppendingPathComponent:@"Payload"];
        NSString *exportBundle = [exportPayload stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]];
        NSString *exports = @"/var/mobile/Library/RedditBox/IPAs";
        [NSFileManager.defaultManager createDirectoryAtPath:exportPayload
            withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:exports
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0700} error:nil];
        exportedIPA = [exports stringByAppendingPathComponent:
            [bundleIdentifier stringByAppendingPathExtension:@"ipa"]];
        NSError *exportError = nil;
        [NSFileManager.defaultManager removeItemAtPath:exportedIPA error:nil];
        BOOL exported = [self _copyBundleAtPath:destination toPath:exportBundle
            error:&exportError] &&
            RBXPrepareStagedExecutable(exportBundle,RBXTransactionsRoot,0,0,&exportError) &&
            [self _archiveTransactionRoot:exportRoot output:exportedIPA
                                    error:&exportError];
        if (RBXCloneContinue(nil)) [NSFileManager.defaultManager removeItemAtPath:exportRoot error:nil];
        if (!exported) {
            if (error) *error = exportError ?: RBXCloneError(33,
                @"cannot export signed clone IPA for MDM");
            return nil;
        }
        chmod(exportedIPA.fileSystemRepresentation, 0600);
    }
    NSDictionary *committedMetadata = [NSDictionary dictionaryWithContentsOfFile:
        [destination stringByAppendingPathComponent:@".redditbox-clone.plist"]];
    NSMutableDictionary *appMetadata = [@{
        @"architecture": @"clonedApp-v2",
        @"sourceBundleIdentifier": (self.appDescriptor[@"sourceBundleIdentifier"]),
        @"bundleIdentifier": bundleIdentifier,
        @"bundlePath": destination ?: @"",
        @"keychainAccessGroup": RBXAppKeychainGroup(self.appDescriptor, bundleIdentifier),
        @"cloneState": @"ready",
        @"appAttestEntitled": @(wantsAttest),
        @"sourceVersion": committedMetadata[@"sourceVersion"] ?: sourceVersion,
        @"sourceBuild": committedMetadata[@"sourceBuild"] ?: sourceBuild,
    } mutableCopy];
    [appMetadata addEntriesFromDictionary:RBXAppKeychainMetadata(self.appDescriptor, bundleIdentifier)];
    if (exportedIPA.length) appMetadata[@"ipaExportPath"] = exportedIPA;
    return appMetadata;
}

- (BOOL)_operation_removeCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return NO;
    @try { return [self _removeCloneForProfile:profile error:error]; }
    @finally { flock(fd, LOCK_UN); close(fd); }
}

- (BOOL)_removeCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    if (![profile isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXCloneError(31, @"clone removal profile is unavailable"); return NO;
    }
    NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
    NSString *container = [profile[@"containerId"] isKindOfClass:NSString.class] ? profile[@"containerId"] : nil;
    if (!container.length || (profile[@"app"] && !app)) {
        if (error) *error = RBXCloneError(31, @"clone removal profile does not identify a valid container"); return NO;
    }
    if (!RBXContainerAvailable(container, error)) return NO;
    // Initial profiles can survive an installation/publication failure before
    // app metadata is saved. The stable container ID still names that clone.
    NSString *bundleIdentifier = RBXAppBundleIdentifier(self.appDescriptor, container);
    NSString *bundlePath = app[@"bundlePath"];
    if ((app[@"bundleIdentifier"] && ![bundleIdentifier isEqual:app[@"bundleIdentifier"]]) ||
        (bundlePath && (![bundlePath isKindOfClass:NSString.class] || !bundlePath.isAbsolutePath))) {
        if (error) *error = RBXCloneError(31, @"clone removal profile does not identify an owned app bundle"); return NO;
    }
    if (!RBXNoPendingInstallation(bundleIdentifier, error)) return NO;
    if (![self _uninstallBundleIdentifier:bundleIdentifier expectedBundlePath:bundlePath error:error]) return NO;
    NSString *exportedIPA = [@"/var/mobile/Library/RedditBox/IPAs" stringByAppendingPathComponent:
        [bundleIdentifier stringByAppendingPathExtension:@"ipa"]];
    [NSFileManager.defaultManager removeItemAtPath:exportedIPA error:nil];
    return YES;
}

- (NSDictionary *)_operation_prepareDeletionForProfile:(NSDictionary *)profile error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return nil;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return nil;
    NSString *job = nil;
    @try {
        NSString *container = [profile isKindOfClass:NSDictionary.class] ? profile[@"containerId"] : nil;
        if (!RBXDeletionContainerID(container) || !RBXDeletionClosed(container, error)) {
            if (error && !*error) *error = RBXCloneError(80, @"deletion profile has no valid container identity"); return nil;
        }
        NSString *bundle = RBXAppBundleIdentifier(self.appDescriptor, container);
        NSString *group = RBXAppKeychainGroup(self.appDescriptor, bundle);
        NSArray *groups = RBXAppKeychainGroups(self.appDescriptor, bundle);
        NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
        if ((profile[@"app"] && !app) || (app[@"bundleIdentifier"] && ![bundle isEqual:app[@"bundleIdentifier"]]) ||
            (app[@"keychainAccessGroup"] && ![group isEqual:app[@"keychainAccessGroup"]]) ||
            (app && !RBXAppKeychainMetadataMatches(self.appDescriptor, bundle, app)) ||
            (app[@"bundlePath"] && (![app[@"bundlePath"] isKindOfClass:NSString.class] || ![app[@"bundlePath"] isAbsolutePath]))) {
            if (error) *error = RBXCloneError(80, @"profile does not identify this clone's exact keychain group and bundle"); return nil;
        }
        if (!RBXNoPendingInstallation(bundle, error) || !RBXDeletionHelpersSafe(bundle, error)) return nil;
        NSArray *transactions = RBXDeletionTransactions(container, bundle, error);
        if (!transactions) return nil;
        NSDictionary *registration = RBXInstalledApplication(bundle, error);
        if (!registration) return nil;
        NSString *evidencePath = [[[RBXTransactionsRoot stringByAppendingPathComponent:@"uninstall-evidence"]
            stringByAppendingPathComponent:bundle] stringByAppendingPathComponent:@"transaction.plist"];
        NSError *readError = nil;
        NSDictionary *capture = RBXReadOwnedPlist(evidencePath, &readError);
        if (readError) { if (error) *error = readError; return nil; }
        if (capture && (![bundle isEqual:capture[@"bundleIdentifier"]] || ![capture[@"formatVersion"] isKindOfClass:NSNumber.class] || [capture[@"formatVersion"] integerValue] != 1)) {
            if (error) *error = RBXCloneError(80, @"pending uninstall evidence belongs to an unknown target"); return nil;
        }
        id proxy = registration[@"proxy"];
        if (proxy && !capture) capture = RBXCaptureRemoval(proxy, bundle, app[@"bundlePath"], error);
        if (proxy && !capture) return nil;
        NSString *bundlePath = capture[@"bundlePath"] ?: app[@"bundlePath"];
        if (capture && app[@"bundlePath"] && ![bundlePath isEqual:[app[@"bundlePath"] stringByResolvingSymlinksInPath]]) {
            if (error) *error = RBXCloneError(80, @"profile and retained uninstall target disagree"); return nil;
        }
        if (proxy) {
            NSString *registered = RBXProxyPath(proxy, @"bundleURL", error);
            if (!registered || ![registered isEqual:bundlePath]) {
                if (error && !*error) *error = RBXCloneError(80, @"deletion registration changed"); return nil;
            }
            NSDictionary *marker = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@".redditbox-clone.plist"]];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if (marker && (![container isEqual:marker[@"containerId"]] || ![group isEqual:marker[@"keychainAccessGroup"]] ||
                !RBXAppKeychainMarkerMatches(self.appDescriptor, bundle, marker))) {
                if (error) *error = RBXCloneError(80, @"installed clone's signed metadata does not match the deletion identity"); return nil;
            }
            NSString *name = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
            if (name.length) {
                if (![name isEqual:name.lastPathComponent] || [@[@".", @".."] containsObject:name]) {
                    if (error) *error = RBXCloneError(80, @"installed clone has an invalid executable name"); return nil;
                }
                job = RBXNewDeletionJob(bundle, error);
                NSString *effectivePath = [job stringByAppendingPathComponent:@"effective.plist"];
                NSString *ldid = RBXExecutable(@"ldid").stringByResolvingSymlinksInPath;
                if (!job || !RBXRunDeletionTool(ldid, @[@"-e", [bundlePath stringByAppendingPathComponent:name]], effectivePath, 16384, error)) return nil;
                NSDictionary *effective = [NSDictionary dictionaryWithContentsOfFile:effectivePath];
                id appGroups = effective[@"com.apple.security.application-groups"];
                if (![group isEqual:effective[@"application-identifier"]] || ![groups isEqual:effective[@"keychain-access-groups"]] ||
                    ![self.appDescriptor[@"teamIdentifier"] isEqual:effective[@"com.apple.developer.team-identifier"]] ||
                    (appGroups && (![appGroups isKindOfClass:NSArray.class] || [appGroups count]))) {
                    if (error) *error = RBXCloneError(80, @"installed clone's effective keychain entitlement differs from its deletion group"); return nil;
                }
            } else if (!readError && ![capture[@"bundleIdentifier"] isEqual:bundle]) {
                if (error) *error = RBXCloneError(80, @"clone signature cannot be inspected and no prior uninstall capture exists"); return nil;
            }
        }
        NSMutableDictionary *target = [RBXAppDeletionTargetIdentity(self.appDescriptor, container) mutableCopy];
        target[@"transactions"] = transactions;
        if (bundlePath) target[@"bundlePath"] = bundlePath;
        if (capture) target[@"installation"] = capture;
        NSString *ipa = [[@"/var/mobile/Library/RedditBox/IPAs" stringByAppendingPathComponent:bundle] stringByAppendingPathExtension:@"ipa"];
        for (NSString *path in @[ipa, self.appDescriptor[@"cloneExportPath"]]) {
            if (!RBXCloneMayMutate(error)) return nil;
            NSError *exportError = nil;
            NSDictionary *record = RBXExportIdentity(path, &exportError);
            if (exportError) { if (error) *error = exportError; return nil; }
            if (!record) continue;
            if ([container isEqual:record[@"containerId"]] && [bundle isEqual:record[@"bundleIdentifier"]])
                target[[path isEqualToString:ipa] ? @"ipa" : @"sharedExport"] = record;
            else if ([path isEqualToString:ipa]) {
                if (error) *error = RBXCloneError(84, @"per-clone IPA path contains an unrelated export"); return nil;
            }
        }
        if (!RBXDeletionTargetValid(target, error)) return nil;
        return target;
    } @catch (NSException *exception) {
        if (error) *error = RBXCloneError(80, @"cannot validate deletion target metadata"); return nil;
    } @finally { RBXFinishDeletionJob(job); flock(fd, LOCK_UN); close(fd); }
}

- (BOOL)_operation_eraseKeychainForDeletionTarget:(NSDictionary *)target error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return NO;
    NSString *job = nil;
    @try {
        if (!RBXDeletionPhase(target, self.appDescriptor, @"prepared", error) || !RBXNoPendingInstallation(target[@"bundleIdentifier"], error)) return NO;
        NSString *bundle = target[@"bundleIdentifier"], *group = target[@"keychainAccessGroup"];
        NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(bundle);
        NSArray *groups = RBXAppKeychainGroups(descriptor, bundle);
        if (![descriptor isEqual:self.appDescriptor] || ![groups.firstObject isEqual:group]) {
            if (error) *error = RBXCloneError(81, @"keychain cleanup target belongs to another app or group policy"); return NO;
        }
        job = RBXNewDeletionJob(bundle, error);
        if (!job) return NO;
        NSString *template = nil;
        for (NSString *candidate in @[RBXInstalledPath(@"/usr/libexec/redditbox-keychain-cleaner")]) {
            if (!RBXCloneMayMutate(error)) return NO;
            NSString *resolved = candidate.stringByResolvingSymlinksInPath;
            struct stat info;
            if (lstat(resolved.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == 0 && !(info.st_mode & 0022)) { template = resolved; break; }
        }
        NSString *binary = [job stringByAppendingPathComponent:@"cleaner"];
        if (!template || ![NSFileManager.defaultManager copyItemAtPath:template toPath:binary error:error] ||
            chown(binary.fileSystemRepresentation, 0, 0) != 0 || chmod(binary.fileSystemRepresentation, 0700) != 0) {
            if (error && !*error) *error = RBXCloneError(81, @"cannot prepare the installed keychain-cleaner template"); return NO;
        }
        NSDictionary *entitlements = @{@"application-identifier": group, @"com.apple.developer.team-identifier": descriptor[@"teamIdentifier"], @"keychain-access-groups": groups};
        NSString *entitlementsPath = [job stringByAppendingPathComponent:@"entitlements.plist"];
        if (![entitlements writeToFile:entitlementsPath atomically:YES]) { if (error) *error = RBXCloneError(81, @"cannot write exact-group helper entitlements"); return NO; }
        NSString *ldid = RBXExecutable(@"ldid").stringByResolvingSymlinksInPath;
        if (!RBXRunDeletionTool(ldid, @[[ @"-S" stringByAppendingString:entitlementsPath], [@"-I" stringByAppendingString:bundle], binary],
            [job stringByAppendingPathComponent:@"sign.stdout"], 4096, error)) return NO;
        NSString *effectivePath = [job stringByAppendingPathComponent:@"effective.plist"];
        if (!RBXRunDeletionTool(ldid, @[@"-e", binary], effectivePath, 16384, error) ||
            ![entitlements isEqual:[NSDictionary dictionaryWithContentsOfFile:effectivePath]]) {
            if (error && !*error) *error = RBXCloneError(81, @"signed cleanup helper does not have exactly the requested group entitlement"); return NO;
        }
        NSString *nonce = NSUUID.UUID.UUIDString;
        NSString *receiptPath = [job stringByAppendingPathComponent:@"receipt.json"];
        NSError *runError = nil;
        if (!RBXRunDeletionTool(binary, @[bundle, nonce], receiptPath, 4096, &runError)) {
            NSString *fence = [job stringByAppendingPathComponent:@"helper-exit-unproven"];
            struct stat fenceInfo, receiptInfo;
            BOOL reaped = lstat(fence.fileSystemRepresentation, &fenceInfo) < 0 && errno == ENOENT;
            BOOL bounded = reaped && lstat(receiptPath.fileSystemRepresentation, &receiptInfo) == 0 &&
                S_ISREG(receiptInfo.st_mode) && receiptInfo.st_uid == 0 && receiptInfo.st_size > 0 && receiptInfo.st_size <= 4096;
            NSData *failureData = bounded ? [NSData dataWithContentsOfFile:receiptPath] : nil;
            id failure = failureData ? [NSJSONSerialization JSONObjectWithData:failureData options:0 error:nil] : nil;
            NSString *stage = [failure isKindOfClass:NSDictionary.class] && [failure[@"stage"] isKindOfClass:NSString.class] ? failure[@"stage"] : nil;
            if (RBXAppKeychainCleanupReceiptBound(descriptor, bundle, nonce, failure) &&
                [@"incomplete" isEqual:failure[@"status"]] && [failure[@"osStatus"] isKindOfClass:NSNumber.class] &&
                stage.length > 0 && stage.length <= 80 &&
                [stage rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz-"].invertedSet].location == NSNotFound) {
                NSInteger status = [failure[@"osStatus"] integerValue];
                NSString *message = (status == errSecInteractionNotAllowed || status == errSecNotAvailable)
                    ? @"Keychain cleanup is unavailable while the device is locked; unlock the iPhone and retry deletion"
                    : [NSString stringWithFormat:@"Keychain cleanup is incomplete at %@ (OSStatus %ld); check helper authorization and retry", stage, (long)status];
                runError = RBXCloneError(81, message);
            }
            if (error) *error = runError;
            return NO;
        }
        NSData *data = [NSData dataWithContentsOfFile:receiptPath options:0 error:error];
        id receipt = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
        if (!RBXAppKeychainCleanupReceiptComplete(descriptor, bundle, nonce, receipt)) {
            if (error) *error = RBXCloneError(81, @"keychain helper did not prove authorized, complete cleanup of the exact target group"); return NO;
        }
        return YES;
    } @finally { RBXFinishDeletionJob(job); flock(fd, LOCK_UN); close(fd); }
}

- (BOOL)_operation_uninstallDeletionTarget:(NSDictionary *)target error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return NO;
    @try {
        if (!RBXDeletionPhase(target, self.appDescriptor, @"keychain-cleared", error) || !RBXDeletionHelpersSafe(target[@"bundleIdentifier"], error) ||
            !RBXNoPendingInstallation(target[@"bundleIdentifier"], error)) return NO;
        NSString *bundle = target[@"bundleIdentifier"];
        NSDictionary *registration = RBXInstalledApplication(bundle, error);
        if (!registration) return NO;
        NSDictionary *capture = target[@"installation"];
        if (registration[@"proxy"] && !capture) {
            if (error) *error = RBXCloneError(80, @"a new installation appeared after deletion preparation"); return NO;
        }
        if (capture) {
            NSString *root = [[RBXTransactionsRoot stringByAppendingPathComponent:@"uninstall-evidence"] stringByAppendingPathComponent:bundle];
            NSError *readError = nil;
            NSDictionary *existing = RBXReadOwnedPlist([root stringByAppendingPathComponent:@"transaction.plist"], &readError);
            if (readError) { if (error) *error = readError; return NO; }
            if (existing) {
                for (NSString *key in @[@"bundlePath", @"dataPath", @"bundleDevice", @"bundleInode", @"dataDevice", @"dataInode", @"installationTransaction", @"paths", @"pluginIDs"]) {
                    if (!RBXCloneMayMutate(error)) return NO;
                    if (![existing[key] isEqual:capture[key]]) { if (error) *error = RBXCloneError(80, @"pending uninstall capture differs from the prepared deletion target"); return NO; }
                }
            } else {
                NSMutableDictionary *evidence = [capture mutableCopy];
                evidence[@"bundleIdentifier"] = bundle; evidence[@"formatVersion"] = @1;
                if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:error] ||
                    !RBXWriteJournal(root, evidence, @"captured", error)) return NO;
            }
        }
        return [self _uninstallBundleIdentifier:bundle expectedBundlePath:target[@"bundlePath"] error:error];
    } @finally { flock(fd, LOCK_UN); close(fd); }
}

- (BOOL)_operation_cleanupArtifactsForDeletionTarget:(NSDictionary *)target error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    int fd = RBXLockTransactions(error);
    if (fd < 0) return NO;
    @try {
        if (!RBXDeletionPhase(target, self.appDescriptor, @"uninstalled", error) || !RBXDeletionHelpersSafe(target[@"bundleIdentifier"], error)) return NO;
        NSDictionary *registration = RBXInstalledApplication(target[@"bundleIdentifier"], error);
        if (!registration) return NO;
        BOOL absent = YES;
        if (registration[@"proxy"] || (target[@"installation"] &&
            (!RBXRemovalPathsAbsent(target[@"installation"][@"paths"], &absent, error) || !absent))) {
            if (error && !*error) *error = RBXCloneError(83, @"clone installation or captured data remains before artifact cleanup"); return NO;
        }
        for (NSDictionary *record in target[@"transactions"]) {
            if (!RBXCloneMayMutate(error)) return NO;
            NSString *root = record[@"root"];
            if (![root isKindOfClass:NSString.class] || ![root.stringByDeletingLastPathComponent isEqualToString:RBXTransactionsRoot] ||
                ![[NSUUID alloc] initWithUUIDString:root.lastPathComponent] ||
                ![target[@"bundleIdentifier"] isEqual:record[@"journal"][@"bundleIdentifier"]] ||
                ![target[@"containerId"] isEqual:record[@"journal"][@"containerId"]]) {
                if (error) *error = RBXCloneError(83, @"saved backup target is outside the owned clone transaction"); return NO;
            }
            struct stat info;
            int status = lstat(root.fileSystemRepresentation, &info);
            if (status < 0 && errno == ENOENT) {
                if (!RBXRemoveArtifactPath(root, error)) return NO;
                continue;
            }
            if (status != 0 || !S_ISDIR(info.st_mode) || info.st_uid != 0 || info.st_dev != [record[@"device"] unsignedLongLongValue] ||
                info.st_ino != [record[@"inode"] unsignedLongLongValue]) {
                if (error) *error = RBXCloneError(83, @"owned transaction backup was replaced after deletion preparation"); return NO;
            }
            NSError *readError = nil;
            NSDictionary *current = RBXReadOwnedPlist([root stringByAppendingPathComponent:@"transaction.plist"], &readError);
            if (readError || (current && ![current isEqual:record[@"journal"]])) {
                if (error) *error = readError ?: RBXCloneError(83, @"owned transaction journal changed during deletion"); return NO;
            }
            if (!RBXRemoveArtifactPath(root, error)) return NO;
        }
        NSArray *remaining = RBXDeletionTransactions(target[@"containerId"], target[@"bundleIdentifier"], error);
        if (!remaining || remaining.count) { if (error && !*error) *error = RBXCloneError(83, @"uncaptured clone backups remain"); return NO; }
        NSString *ipa = [[@"/var/mobile/Library/RedditBox/IPAs" stringByAppendingPathComponent:target[@"bundleIdentifier"]] stringByAppendingPathExtension:@"ipa"];
        for (NSString *key in @[@"ipa", @"sharedExport"]) {
            if (!RBXCloneMayMutate(error)) return NO;
            NSString *path = [key isEqualToString:@"ipa"] ? ipa : self.appDescriptor[@"cloneExportPath"];
            if (!RBXCleanExportRecord(target, key, path, error)) return NO;
        }
        NSString *quarantine = RBXExportQuarantineRoot(target[@"bundleIdentifier"]);
        struct stat quarantineInfo;
        int quarantineStatus = lstat(quarantine.fileSystemRepresentation, &quarantineInfo);
        if (quarantineStatus == 0) {
            NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:quarantine error:error];
            if (!entries || entries.count) {
                if (error && !*error) *error = RBXCloneError(84, @"export quarantine still contains recovery artifacts"); return NO;
            }
            if (!RBXRemoveArtifactPath(quarantine, error)) return NO;
        } else if (errno != ENOENT) { if (error) *error = RBXCloneError(84, @"cannot verify export quarantine cleanup"); return NO; }
        NSString *bundle = target[@"bundleIdentifier"];
        if (!RBXRemoveArtifactPath(RBXDeletionJobsRoot(bundle), error)) return NO;
        return [RBXDeletionJobsRoot(bundle) isEqualToString:RBXLegacyDeletionJobsRoot(bundle)] ||
            RBXRemoveArtifactPath(RBXLegacyDeletionJobsRoot(bundle), error);
    } @finally { flock(fd, LOCK_UN); close(fd); }
}

- (BOOL)validateCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return NO; }
    if (!RBXContainerAvailable(profile[@"containerId"], error)) return NO;
    NSDictionary *app = profile[@"app"];
    NSString *bundlePath = app[@"bundlePath"];
    NSString *bundleIdentifier = app[@"bundleIdentifier"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@".redditbox-clone.plist"]];
    NSString *installedPath = [self _installedBundleForIdentifier:bundleIdentifier];
    BOOL valid = bundlePath.length && bundleIdentifier.length && RBXBootstrapIsRedacted(bundlePath) &&
        RBXBootstrapMatchesIdentity(bundlePath, profile) &&
        [app[@"architecture"] isEqualToString:@"clonedApp-v2"] &&
        [installedPath isEqualToString:bundlePath] &&
        [info[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier] &&
        RBXAppKeychainInfoMatches(info, self.appDescriptor, bundleIdentifier) &&
        [info[@"SBAppTags"] containsObject:@"hidden"] &&
        [info[@"RBXLauncherOnly"] boolValue] &&
        [metadata[@"containerId"] isEqualToString:profile[@"containerId"]] &&
        [metadata[@"installer"] isEqualToString:@"appinst"] &&
        [metadata[@"launcherOnly"] boolValue] &&
        [metadata[@"keychainAccessGroup"] isEqualToString:app[@"keychainAccessGroup"]] &&
        [app[@"keychainAccessGroup"] isEqual:RBXAppKeychainGroup(self.appDescriptor, bundleIdentifier)] &&
        RBXAppKeychainMarkerMatches(self.appDescriptor, bundleIdentifier, metadata) &&
        RBXAppKeychainMetadataMatches(self.appDescriptor, bundleIdentifier, app) &&
        [self dataContainerForBundleIdentifier:bundleIdentifier].length > 0 &&
        ![NSFileManager.defaultManager fileExistsAtPath:
            [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"]];
    if (!valid && error) *error = RBXCloneError(20, @"clone metadata or signature inputs are invalid");
    return valid;
}

- (NSString *)_operation_exportIPAForProfile:(NSDictionary *)profile error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return nil;
    if (![self validateCloneForProfile:profile error:error]) return nil;
    NSString *bundlePath = profile[@"app"][@"bundlePath"];
    NSString *bundleIdentifier = profile[@"app"][@"bundleIdentifier"];
    NSString *root = [RBXTransactionsRoot stringByAppendingPathComponent:
        NSUUID.UUID.UUIDString];
    NSString *payload = [root stringByAppendingPathComponent:@"Payload"];
    NSString *bundle = [payload stringByAppendingPathComponent:self.appDescriptor[@"sourceBundleName"]];
    NSString *output = self.appDescriptor[@"cloneExportPath"];
    NSFileManager *fm = NSFileManager.defaultManager;
    // A completed but unconsumed receipt still owns the shared export. Never
    // overwrite it with another profile while the launcher is showing a sheet.
    if ([fm fileExistsAtPath:output]) {
        if (error) *error = RBXCloneError(409, @"An IPA export is awaiting collection. Return to the launcher to finish that export before requesting another.");
        return nil;
    }
    [fm createDirectoryAtPath:payload withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    BOOL exported = [self _copyBundleAtPath:bundlePath toPath:bundle error:error] &&
        RBXPrepareStagedExecutable(bundle,RBXTransactionsRoot,0,0,error) &&
        [self _archiveTransactionRoot:root output:output error:error];
    if (RBXCloneContinue(nil)) [fm removeItemAtPath:root error:nil];
    if (!exported) return nil;
    chmod(output.fileSystemRepresentation, 0600);
    chown(output.fileSystemRepresentation, 501, 501);
    NSLog(@"redditboxd: launcher MDM export ready for %@", bundleIdentifier);
    return output;
}

- (BOOL)verifyManagedInstallationForProfile:(NSDictionary *)profile
                                      error:(NSError **)error {
    NSString *blocked = RBXAppCloneBlockReason(self.appDescriptor, profile, YES);
    if (blocked) { if (error) *error = RBXCloneError(91, blocked); return NO; }
    NSString *bundleIdentifier = profile[@"app"][@"bundleIdentifier"];
    if (!bundleIdentifier.length) {
        if (error) *error = RBXCloneError(34, @"clone has no bundle identifier");
        return NO;
    }
    void *framework = dlopen(
        "/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
        RTLD_NOW);
    if (!framework) {
        framework = dlopen(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
            RTLD_NOW);
    }
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:lookup]) {
        if (framework) dlclose(framework);
        if (error) *error = RBXCloneError(35,
            @"cannot query LaunchServices managed-app state");
        return NO;
    }
    id (*sendObject)(id, SEL, id) = (void *)objc_msgSend;
    id proxy = sendObject(proxyClass, lookup, bundleIdentifier);
    SEL managedSelector = NULL;
    for (NSString *candidate in @[@"isManaged", @"isManagedApp"]) {
        SEL selector = NSSelectorFromString(candidate);
        if ([proxy respondsToSelector:selector]) {
            managedSelector = selector;
            break;
        }
    }
    if (!proxy || !managedSelector) {
        if (framework) dlclose(framework);
        if (error) *error = RBXCloneError(36,
            @"this iOS build does not expose verifiable managed-app state");
        return NO;
    }
    BOOL (*sendBool)(id, SEL) = (void *)objc_msgSend;
    BOOL managed = sendBool(proxy, managedSelector);
    if (framework) dlclose(framework);
    if (!managed && error) {
        *error = RBXCloneError(37,
            @"clone is locally installed but not MDM-managed; per-app VPN is not guaranteed");
    }
    return managed;
}

- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundleIdentifier {
    if (!RBXAppOwnsCloneBundleIdentifier(self.appDescriptor, bundleIdentifier)) return nil;
    NSArray<NSString *> *roots = @[@"/var/mobile/Containers/Data/Application",
                                    @"/var/containers/Data/Application"];
    for (NSString *root in roots) {
        if (!RBXCloneContinue(nil)) return nil;
        NSArray<NSString *> *children =
            [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *child in children) {
            if (!RBXCloneContinue(nil)) return nil;
            NSString *candidate = [root stringByAppendingPathComponent:child];
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
                [candidate stringByAppendingPathComponent:
                    @".com.apple.mobile_container_manager.metadata.plist"]];
            NSString *identifier = metadata[@"MCMMetadataIdentifier"];
            if ([identifier isEqualToString:bundleIdentifier]) return candidate;
        }
    }
    return nil;
}

- (BOOL)_operation_syncProfile:(NSDictionary *)profile error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *bundleIdentifier = profile[@"app"][@"bundleIdentifier"];
    NSString *container = [self dataContainerForBundleIdentifier:bundleIdentifier];
    if (!container.length) {
        if (error) *error = RBXCloneError(21, @"clone OS data container does not exist yet");
        return NO;
    }
    // A recorded, inode-bound closed home may be serviced by root without
    // exposing it to mobile. All child directories remain mobile-owned.
    BOOL sealed=[RBXStorageAccess ownsClosedHome:container bundleIdentifier:bundleIdentifier error:nil];
    NSString *support = sealed ? RBXCloneSupportDirectoryWithRootOwner(container,501,501,0,error)
                               : RBXCloneSupportDirectory(container,501,501,error);
    if (!support) return NO;
    NSString *path = [support stringByAppendingPathComponent:@"profile.json"];
    if (!RBXCloneMayMutate(error)) return NO;
    if (![RBXProfileIO writeProfile:RBXProfileForTransport(profile) containerId:profile[@"containerId"] toPath:path error:error]) return NO;
    if (chmod(path.fileSystemRepresentation, 0600) != 0 || chown(path.fileSystemRepresentation, 501, 501) != 0) {
        if (error) *error = RBXCloneError(21, @"clone profile ownership/permissions could not be restricted"); return NO;
    }
    return YES;
}

- (BOOL)writeGateControlPlist:(NSDictionary *)document profile:(NSDictionary *)profile
                        name:(NSString *)name error:(NSError **)error {
    BOOL leaseFile = [name isEqual:@"com.redditbox.network-lease.plist"];
    if (!leaseFile && ![name isEqual:@"com.redditbox.firewall-status.plist"]) {
        if (error) *error = RBXCloneError(91, @"Gate maintenance is restricted to lease and firewall state"); return NO;
    }
    NSDictionary *(^currentLease)(void) = ^{
        return [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist"];
    };
    NSDictionary *lease = currentLease();
    NSString *containerID = lease[@"containerId"], *bundle = lease[@"bundleIdentifier"];
    if (![document isKindOfClass:NSDictionary.class] || !RBXDeletionContainerID(containerID) ||
        ![RBXAppDescriptorForProfile(profile) isEqual:self.appDescriptor] ||
        ![RBXAppBundleIdentifier(self.appDescriptor, containerID) isEqual:bundle] ||
        ![bundle isEqual:profile[@"app"][@"bundleIdentifier"]] ||
        (profile[@"containerId"] && ![containerID isEqual:profile[@"containerId"]]) ||
        (leaseFile && ![document isEqual:lease])) {
        if (error) *error = RBXCloneError(91, @"Gate mirror is not the exact current clone lease"); return NO;
    }
    for (NSString *key in @[@"containerId", @"bundleIdentifier", @"generation", @"bootEpoch", @"state"]) {
        if (![lease[key] isKindOfClass:NSString.class] || ![lease[key] length] ||
            ![lease[key] isEqual:document[key]]) {
            if (error) *error = RBXCloneError(91, @"Gate mirror identity or generation is stale"); return NO;
        }
    }
    BOOL closed = [lease[@"state"] isEqual:@"closed"];
    RBXOperationContext *context = RBXOperationContext.currentContext;
    BOOL (^authorizationCurrent)(void) = ^BOOL {
        if (![lease isEqual:currentLease()]) return NO;
        if (closed) return YES;
        return [RBXOperationContext checkSafetyFence:nil] && (!context || [context check:nil]) &&
            [lease[@"bootEpoch"] isEqual:RBXOperationContext.daemonBootEpoch] &&
            RBXHeartbeatFresh(lease[@"heartbeatAt"], NSDate.date.timeIntervalSince1970);
    };
    if (!authorizationCurrent()) {
        if (error) *error = RBXCloneError(91, @"Gate authorization was revoked before mirroring"); return NO;
    }
    NSDictionary *registration = RBXInstalledApplication(bundle, error);
    if (!registration) return NO;
    if (!registration[@"proxy"]) return closed;
    SEL dataSelector = NSSelectorFromString(@"dataContainerURL");
    id proxy = registration[@"proxy"];
    if ([proxy respondsToSelector:dataSelector] &&
        !((id (*)(id, SEL))objc_msgSend)(proxy, dataSelector)) {
        // A verified first-launch registration can precede sandbox allocation.
        return closed || [lease[@"state"] isEqual:@"armed"];
    }
    NSString *container = RBXProxyPath(registration[@"proxy"], @"dataContainerURL", error);
    if (!container || !RBXValidateDataRemovalPath(container, bundle, NO, error)) return NO;
    NSString *directory = [container stringByAppendingPathComponent:@"Library/Preferences"];
    if (!authorizationCurrent() || ![NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSMutableDictionary *scoped = [document mutableCopy];
    NSString *epoch = RBXEpochForClone(document[@"bootEpoch"], bundle);
    if (!epoch.length) { if (error) *error = RBXCloneError(91, @"Clone epoch derivation failed"); return NO; }
    scoped[@"bootEpoch"] = epoch;
    [scoped removeObjectsForKeys:@[@"controlIPs", @"lastExitIP"]];
    if (!authorizationCurrent() || ![scoped writeToFile:path atomically:YES]) {
        if (error && !*error) *error = RBXCloneError(91, @"Gate mirror could not be published"); return NO;
    }
    chmod(path.fileSystemRepresentation, 0600); chown(path.fileSystemRepresentation, 501, 501);
    return YES;
}

- (BOOL)_operation_writeControlPlist:(NSDictionary *)document
                  profile:(NSDictionary *)profile
                     name:(NSString *)name
                    error:(NSError **)error {
    if (!RBXCloneMayMutate(error)) return NO;
    NSString *container = [self dataContainerForBundleIdentifier:profile[@"app"][@"bundleIdentifier"]];
    if (!container.length) {
        if (error) *error = RBXCloneError(22, @"cannot locate clone data container");
        return NO;
    }
    NSString *directory = [container stringByAppendingPathComponent:@"Library/Preferences"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (!RBXCloneMayMutate(error)) return NO;
    if (![document writeToFile:path atomically:YES]) {
        if (error) *error = RBXCloneError(23, @"cannot write clone-local control state");
        return NO;
    }
    chmod(path.fileSystemRepresentation, 0600);
    chown(path.fileSystemRepresentation, 501, 501);
    return YES;
}

@end
