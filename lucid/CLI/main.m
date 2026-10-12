#import <Foundation/Foundation.h>
#import "../HelperClient/LBXHelperClient.h"
#import "../HelperClient/LBXContainerStore.h"
#import "../Switching/LBXSocialBoxProduct.h"

static BOOL gJSON = NO;

static void PrintUsage(void) {
    fputs(
        "SocialBoxCLI — source rebuild (com.socialbox.helper.xpc)\n"
        "\n"
        "Usage:\n"
        "  SocialBoxCLI list [--json]\n"
        "  SocialBoxCLI create --name <name> [--apps ig,fb] [--no-activate] [--json]\n"
        "  SocialBoxCLI activate <id> [--json]\n"
        "  SocialBoxCLI rename <id> <name> [--json]\n"
        "  SocialBoxCLI delete <id> [--json]\n"
        "  SocialBoxCLI verify [--container N] [--json]\n"
        "  SocialBoxCLI ping [--json]\n"
        "\n"
        "Also accepted (A/B/A scripts):\n"
        "  SocialBoxCLI container list [bundleID] [--json]\n"
        "  SocialBoxCLI container create --name <name> --apps <bundleID,...> [--no-activate] [--json]\n"
        "  SocialBoxCLI container activate <id> [--json]\n"
        "  SocialBoxCLI container delete <id> [--json]\n"
        "  SocialBoxCLI container verify-isolation --container N [--json]\n"
        "\n",
        stderr);
}

static int EmitJSON(id obj) {
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        fputs("{\"error\":\"invalid json object\"}\n", stderr);
        return 2;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return 2;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    return 0;
}

static int EmitError(NSString *message, int code) {
    if (gJSON) return EmitJSON(@{@"ok" : @NO, @"error" : message ?: @"error"});
    fprintf(stderr, "Error: %s\n", message.UTF8String ?: "error");
    return code;
}

static NSArray<NSString *> *ParseApps(NSString *raw) {
    if (![raw isKindOfClass:NSString.class] || raw.length == 0) {
        return @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
    }
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByString:@","]) {
        NSString *trim = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trim isEqualToString:@"ig"] || [trim isEqualToString:@"instagram"]) {
            [apps addObject:LBXContainerStoreInstagram];
        } else if ([trim isEqualToString:@"fb"] || [trim isEqualToString:@"facebook"]) {
            [apps addObject:LBXContainerStoreFacebook];
        } else if (trim.length) {
            [apps addObject:trim];
        }
    }
    if (apps.count == 0) {
        return @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
    }
    return apps;
}

static int CmdPing(LBXHelperClient *helper) {
    NSError *error = nil;
    if (![helper ping:&error]) {
        return EmitError(error.localizedDescription ?: @"ping failed", 1);
    }
    if (gJSON) {
        return EmitJSON(@{
            @"ok" : @YES,
            @"mach" : @LBX_SOCIALBOX_HELPER_MACH,
            @"helperPath" : @LBX_SOCIALBOX_HELPER_PATH,
        });
    }
    printf("pong %s\n", LBX_SOCIALBOX_HELPER_MACH);
    return 0;
}

static int CmdList(LBXContainerStore *store, NSString *bundleFilter) {
    NSError *error = nil;
    NSArray<LBXContainerRecord *> *rows = [store listContainers:&error];
    if (!rows) return EmitError(error.localizedDescription ?: @"list failed", 1);
    NSMutableArray *jsonRows = [NSMutableArray array];
    for (LBXContainerRecord *row in rows) {
        if (bundleFilter.length && ![row.apps containsObject:bundleFilter]) continue;
        long long ig = [store activeContainerIDForBundleID:LBXContainerStoreInstagram error:nil];
        long long fb = [store activeContainerIDForBundleID:LBXContainerStoreFacebook error:nil];
        BOOL active = (row.containerID == ig) || (row.containerID == fb);
        NSDictionary *entry = @{
            @"id" : @(row.containerID),
            @"name" : row.name ?: @"",
            @"apps" : row.apps ?: @[],
            @"active" : @(active),
            @"activeInstagram" : @(row.containerID == ig),
            @"activeFacebook" : @(row.containerID == fb),
        };
        [jsonRows addObject:entry];
        if (!gJSON) {
            printf("%lld\t%s\t%s\t%s\n", row.containerID, active ? "active" : "idle",
                   row.name.UTF8String ?: "",
                   [row.apps componentsJoinedByString:@","].UTF8String ?: "");
        }
    }
    if (gJSON) return EmitJSON(@{@"ok" : @YES, @"containers" : jsonRows});
    if (jsonRows.count == 0) {
        fputs("(no containers)\n", stdout);
    }
    return 0;
}

static int CmdCreate(LBXHelperClient *helper, LBXContainerStore *store, NSArray<NSString *> *args) {
    NSString *name = nil;
    NSString *appsRaw = @"ig,fb";
    BOOL activate = YES;
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--name"] && i + 1 < args.count) {
            name = args[++i];
        } else if ([arg isEqualToString:@"--apps"] && i + 1 < args.count) {
            appsRaw = args[++i];
        } else if ([arg isEqualToString:@"--no-activate"]) {
            activate = NO;
        } else if ([arg isEqualToString:@"--json"]) {
            gJSON = YES;
        } else if (![arg hasPrefix:@"--"] && !name) {
            // Positional: container create <bundleID> [name]
            if ([arg containsString:@"."]) {
                appsRaw = arg;
            } else {
                name = arg;
            }
        }
    }
    NSArray<NSString *> *apps = ParseApps(appsRaw);
    NSError *error = nil;
    if (![helper ping:&error]) {
        return EmitError(error.localizedDescription ?: @"helper ping failed", 1);
    }
    long long cid = [store nextContainerID:&error];
    if (cid < 1) return EmitError(@"could not allocate container id", 1);
    if (!name.length) name = [NSString stringWithFormat:@"Container %lld", cid];

    for (NSString *bundleID in apps) {
        if (![helper bootstrapBundleID:bundleID containerID:cid error:&error]) {
            return EmitError(
                [NSString stringWithFormat:@"bootstrap %@ failed: %@", bundleID,
                                           error.localizedDescription ?: @"?"],
                1);
        }
        [helper chownRecursiveToMobileAtPath:[store controlPathForBundleID:bundleID containerID:cid]
                                       error:nil];
    }
    [helper chownRecursiveToMobileAtPath:[store profilePathForContainerID:cid] error:nil];
    [helper chownRecursiveToMobileAtPath:store.controlRoot error:nil];

    LBXContainerRecord *record = [LBXContainerRecord new];
    record.containerID = cid;
    record.name = name;
    record.apps = apps;
    if (![store upsertContainer:record error:&error]) {
        return EmitError(error.localizedDescription ?: @"metadata write failed", 1);
    }

    if (activate && ![store activateContainerID:cid forBundleIDs:apps helper:helper error:&error]) {
        return EmitError(error.localizedDescription ?: @"activate failed", 1);
    }

    if (gJSON) {
        return EmitJSON(@{
            @"ok" : @YES,
            @"id" : @(cid),
            @"name" : name,
            @"apps" : apps,
            @"activated" : @(activate),
        });
    }
    printf("created id=%lld name=%s activated=%s\n", cid, name.UTF8String,
           activate ? "yes" : "no");
    return 0;
}

static int CmdActivate(LBXHelperClient *helper, LBXContainerStore *store, NSArray<NSString *> *args) {
    if (args.count < 1) return EmitError(@"activate requires <id>", 2);
    long long cid = args[0].longLongValue;
    if (cid < 1) return EmitError(@"invalid container id", 2);
    NSString *bundleFilter = nil;
    for (NSUInteger i = 1; i < args.count; i++) {
        if ([args[i] isEqualToString:@"--json"]) {
            gJSON = YES;
        } else if (![args[i] hasPrefix:@"--"]) {
            bundleFilter = args[i];
        }
    }
    NSError *error = nil;
    LBXContainerRecord *record = [store containerWithID:cid error:&error];
    if (!record) return EmitError(error.localizedDescription ?: @"container not found", 1);
    if (![helper ping:&error]) {
        return EmitError(error.localizedDescription ?: @"helper ping failed", 1);
    }
    if (bundleFilter.length && ![record.apps containsObject:bundleFilter]) {
        return EmitError(@"activate still switches the whole phone; unknown bundle filter", 2);
    }
    NSArray *apps = @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
    if (![store activateContainerID:cid forBundleIDs:apps helper:helper error:&error]) {
        return EmitError(error.localizedDescription ?: @"activate failed", 1);
    }
    NSMutableDictionary *loaded = [NSMutableDictionary dictionary];
    for (NSString *bundleID in apps) {
        loaded[bundleID] = @([helper loadedContainerForBundleID:bundleID error:nil]);
    }
    if (gJSON) {
        return EmitJSON(@{@"ok" : @YES, @"id" : @(cid), @"apps" : apps, @"loaded" : loaded});
    }
    printf("activated %lld for %s\n", cid,
           [apps componentsJoinedByString:@","].UTF8String ?: "");
    return 0;
}

static int CmdRename(LBXContainerStore *store, NSArray<NSString *> *args) {
    NSMutableArray<NSString *> *positional = [NSMutableArray array];
    for (NSString *arg in args) {
        if (![arg hasPrefix:@"--"]) [positional addObject:arg];
    }
    if (positional.count < 2) return EmitError(@"rename requires <id> <name>", 2);
    long long cid = positional[0].longLongValue;
    NSString *name = [[positional subarrayWithRange:NSMakeRange(1, positional.count - 1)]
        componentsJoinedByString:@" "];
    NSError *error = nil;
    if (![store renameContainerID:cid toName:name error:&error]) {
        return EmitError(error.localizedDescription ?: @"rename failed", 1);
    }
    if (gJSON) return EmitJSON(@{@"ok" : @YES, @"id" : @(cid), @"name" : name});
    printf("renamed %lld to %s\n", cid, name.UTF8String);
    return 0;
}

static int CmdDelete(LBXHelperClient *helper, LBXContainerStore *store, NSArray<NSString *> *args) {
    NSMutableArray<NSString *> *positional = [NSMutableArray array];
    for (NSString *arg in args) {
        if (![arg hasPrefix:@"--"]) [positional addObject:arg];
    }
    if (positional.count < 1) return EmitError(@"delete requires <id>", 2);
    long long cid = positional[0].longLongValue;
    if (cid < 1) return EmitError(@"invalid container id", 2);
    NSError *error = nil;
    if (![helper ping:&error]) return EmitError(error.localizedDescription ?: @"helper ping failed", 1);
    if (![store deleteContainerID:cid helper:helper error:&error]) {
        return EmitError(error.localizedDescription ?: @"delete failed", 1);
    }
    if (gJSON) return EmitJSON(@{@"ok" : @YES, @"id" : @(cid), @"deleted" : @YES});
    printf("deleted %lld\n", cid);
    return 0;
}

static int CmdVerify(LBXHelperClient *helper, LBXContainerStore *store, NSArray<NSString *> *args) {
    long long cid = 0;
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *arg = args[i];
        if (([arg isEqualToString:@"--container"] || [arg isEqualToString:@"-c"]) && i + 1 < args.count) {
            cid = args[++i].longLongValue;
        } else if ([arg isEqualToString:@"--json"]) {
            gJSON = YES;
        } else if (![arg hasPrefix:@"--"] && cid < 1) {
            cid = arg.longLongValue;
        }
    }
    if (cid < 1) {
        cid = [store activeContainerIDForBundleID:LBXContainerStoreInstagram error:nil];
    }
    if (cid < 1) return EmitError(@"verify requires --container N (or an active selection)", 2);

    NSDictionary *report = [store verifyDataSeparationForContainerID:cid helper:helper];
    BOOL pass = [report[@"pass"] boolValue];
    if (gJSON) {
        NSMutableDictionary *out = [report mutableCopy];
        out[@"ok"] = @(pass);
        return EmitJSON(out);
    }
    printf("cid=%lld selection=%s loaded=%s shared=%s live=%s slots=%s keychain=%s\n", cid,
           [report[@"selection"][@"pass"] boolValue] ? "PASS" : "FAIL",
           [report[@"loaded"][@"pass"] boolValue] ? "PASS" : "FAIL",
           [report[@"sharedFolders"][@"pass"] boolValue] ? "PASS" : "FAIL",
           [report[@"liveRoots"][@"pass"] boolValue] ? "PASS" : "FAIL",
           [report[@"slots"][@"pass"] boolValue] ? "PASS" : "FAIL",
           [report[@"keychain"][@"status"] UTF8String] ?: "NOT_SEPARATED");
    printf("loadedIG=%lld loadedFB=%lld loadedShared=%lld groups=%lu pluginKit=%lu isolationVerified=NO\n",
           [report[@"loaded"][@"instagram"] longLongValue], [report[@"loaded"][@"facebook"] longLongValue],
           [report[@"loaded"][@"shared"] longLongValue],
           (unsigned long)[report[@"sharedFolders"][@"groups"] count],
           (unsigned long)[report[@"sharedFolders"][@"pluginKit"] count]);
    return pass ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            PrintUsage();
            return 2;
        }
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
        for (NSString *arg in args) {
            if ([arg isEqualToString:@"--json"]) gJSON = YES;
        }

        NSString *cmd = args[0];
        NSArray<NSString *> *rest = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];
        if ([cmd isEqualToString:@"container"] && rest.count >= 1) {
            cmd = rest[0];
            rest = rest.count > 1 ? [rest subarrayWithRange:NSMakeRange(1, rest.count - 1)] : @[];
            if ([cmd isEqualToString:@"verify-isolation"]) cmd = @"verify";
        }

        LBXHelperClient *helper = [LBXHelperClient new];
        LBXContainerStore *store = [LBXContainerStore new];

        if ([cmd isEqualToString:@"help"] || [cmd isEqualToString:@"-h"] ||
            [cmd isEqualToString:@"--help"]) {
            PrintUsage();
            return 0;
        }
        if ([cmd isEqualToString:@"ping"]) return CmdPing(helper);
        if ([cmd isEqualToString:@"list"]) {
            NSString *filter = nil;
            for (NSString *arg in rest) {
                if (![arg hasPrefix:@"--"]) {
                    filter = arg;
                    break;
                }
            }
            return CmdList(store, filter);
        }
        if ([cmd isEqualToString:@"create"]) return CmdCreate(helper, store, rest);
        if ([cmd isEqualToString:@"activate"]) return CmdActivate(helper, store, rest);
        if ([cmd isEqualToString:@"rename"]) return CmdRename(store, rest);
        if ([cmd isEqualToString:@"delete"]) return CmdDelete(helper, store, rest);
        if ([cmd isEqualToString:@"verify"]) return CmdVerify(helper, store, rest);
        if ([cmd isEqualToString:@"location"] && rest.count >= 1) {
            NSError *error = nil;
            if ([rest[0] isEqualToString:@"stop"]) {
                if (![helper stopLocationSimulation:&error]) return EmitError(error.localizedDescription, 1);
                printf("location stopped\n");
                return 0;
            }
            if ([rest[0] isEqualToString:@"start"] && rest.count >= 3) {
                NSString *detail = nil;
                if (![helper startLocationAtLatitude:rest[1].doubleValue
                                           longitude:rest[2].doubleValue
                                              detail:&detail
                                               error:&error])
                    return EmitError(error.localizedDescription, 1);
                printf("%s\n", detail.UTF8String ?: "location started");
                return 0;
            }
        }

        PrintUsage();
        return EmitError([NSString stringWithFormat:@"unknown command '%@'", cmd], 2);
    }
}
