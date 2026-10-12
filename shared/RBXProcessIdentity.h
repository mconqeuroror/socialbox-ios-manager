#pragma once
#include <stdint.h>
#include <sys/types.h>
#include "RBXProc.h"

// A process observation, not a reusable authority or a launch/network fence.
// The caller must separately establish that this executable belongs to its app.
typedef struct {
    pid_t pid;
    int64_t startSeconds;
    int32_t startMicroseconds;
    char executable[PROC_PIDPATHINFO_MAXSIZE];
} RBXObservedProcess;

typedef enum {
    RBXProcessObserved = 0,
    RBXProcessGone,
    RBXProcessChanged,
    RBXProcessDenied,
    RBXProcessTerminationRequested
} RBXProcessIdentityResult;

RBXProcessIdentityResult RBXObserveProcess(pid_t pid, RBXObservedProcess *result);
// Revalidates birth/path and the RunningBoard handle audit token, then submits
// an identity+PID handle predicate. No direct PID/name signal fallback. iOS owns
// final dispatch; this is not a proof of atomic PID-version-bound termination.
// A successful request is NOT evidence of completed exit; observe absence after.
RBXProcessIdentityResult RBXTerminateObservedProcess(const RBXObservedProcess *expected);
