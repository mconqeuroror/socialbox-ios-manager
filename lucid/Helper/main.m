#import <Foundation/Foundation.h>
#import "LBXHelperService.h"
#import "LBXHelperLocation.h"
#import "../Switching/LBXSocialBoxProduct.h"
#include <signal.h>
#include <unistd.h>
#include <os/log.h>
#include <string.h>
#include <stdio.h>

static int LBXLocationArgv(int argc, char *argv[]) {
    if (argc < 3 || strcmp(argv[1], "location") != 0) return -1;
    NSString *detail = nil;
    NSError *error = nil;
    if (strcmp(argv[2], "stop") == 0) {
        if (!LBXHelperStopLocationSimulation(&detail, &error)) {
            fprintf(stderr, "Error: %s\n", error.localizedDescription.UTF8String ?: "stop failed");
            return 1;
        }
        puts(detail.UTF8String ?: "location stopped");
        return 0;
    }
    if (strcmp(argv[2], "start") == 0 && argc >= 5) {
        if (!LBXHelperStartLocationSimulation(strtod(argv[3], NULL), strtod(argv[4], NULL), &detail, &error)) {
            fprintf(stderr, "Error: %s\n", error.localizedDescription.UTF8String ?: "start failed");
            return 1;
        }
        puts(detail.UTF8String ?: "location started");
        return 0;
    }
    fputs("SocialBoxHelper location start <lat> <lon>\nSocialBoxHelper location stop\n", stderr);
    return 2;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        signal(SIGCHLD, SIG_IGN);

        if (getuid() != 0 || geteuid() != 0) {
            fputs("SocialBoxHelper must run as root\n", stderr);
            return 77;
        }

        int locationRc = LBXLocationArgv(argc, argv);
        if (locationRc >= 0) return locationRc;

        LBXHelperService *service = [LBXHelperService new];
        NSXPCListener *listener =
            [[NSXPCListener alloc] initWithMachServiceName:@LBX_SOCIALBOX_HELPER_MACH];
        listener.delegate = service;
        [listener resume];
        os_log(OS_LOG_DEFAULT, "SocialBoxHelper listening on %{public}s", LBX_SOCIALBOX_HELPER_MACH);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
