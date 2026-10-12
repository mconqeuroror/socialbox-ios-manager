#import "LBXDarwinDrainBackend.h"
#include <unistd.h>
#include <stdio.h>

int main(int argc, char **argv) { @autoreleasepool {
    // No shell fragments, arbitrary paths, PIDs, IPC listener or setuid mode.
    if (argc != 4 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "drain"))) {
        fputs("usage: socialbox-drain inspect|drain REGISTERED-APP-BUNDLE-ID REQUEST-UUID\n", stderr);
        return 64;
    }
    if (getuid() != 0 || geteuid() != 0) { fputs("Root acceptance session required\n", stderr); return 77; }
    // The cooperative operation deadline cannot interrupt LaunchServices or a
    // blocked filesystem/syscall. A separate watchdog ends this one-shot helper;
    // missing/truncated output or nonzero exit can never be a drain receipt.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ _exit(124); });
    NSDictionary *receipt = LBXDrainApplication([LBXDarwinDrainBackend new], @(argv[2]), @(argv[3]),
        2.0, !strcmp(argv[1], "drain"));
    NSData *json = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:nil];
    if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF || fflush(stdout)) return 74;
    return [receipt[@"status"] isEqual:@"observed_absent"] ? 0 :
        [receipt[@"status"] isEqual:@"observed_running"] ? 3 : 1;
}}
