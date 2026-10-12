#include "../daemon/RBXMemoryBudget.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

static RBXMemoryLimits current;
static int reads, writes, failRead, failWrite, ignoreWrite;
static int mockControl(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size) {
    assert(pid == 42 && flags == 0 && size == sizeof(current));
    if (command == 8) {
        reads++;
        if (failRead) { errno = EACCES; return -1; }
        memcpy(buffer, &current, size);
        return 0;
    }
    assert(command == 7);
    writes++;
    if (failWrite) { errno = EPERM; return -1; }
    if (!ignoreWrite) memcpy(&current, buffer, size);
    return 0;
}
static void reset(int32_t active, int32_t inactive) {
    current = (RBXMemoryLimits){active, 0, inactive, 1};
    reads = writes = failRead = failWrite = ignoreWrite = 0;
}
int main(void) {
    RBXMemoryLimits result;
    reset(18, 18);
    assert(RBXApplyMemoryBudget(mockControl, 42, 256, &result) == 0);
    assert(result.active == 256 && result.inactive == 256);
    assert(result.activeAttributes == 0 && result.inactiveAttributes == 1);
    assert(reads == 2 && writes == 1);
    reset(512, -1);
    assert(RBXApplyMemoryBudget(mockControl, 42, 256, &result) == 0);
    assert(result.active == 512 && result.inactive == -1 && writes == 0);
    reset(18, 512);
    assert(RBXApplyMemoryBudget(mockControl, 42, 256, &result) == 0);
    assert(result.active == 256 && result.inactive == 512);
    reset(18, 18); failRead = 1;
    assert(RBXApplyMemoryBudget(mockControl, 42, 256, &result) == -1 && errno == EACCES && writes == 0);
    reset(18, 18); failWrite = 1;
    assert(RBXApplyMemoryBudget(mockControl, 42, 256, &result) == -1 && errno == EPERM && current.active == 18);
    reset(18, 18); ignoreWrite = 1;
    assert(RBXApplyMemoryBudget(mockControl, 42, 256, &result) == -1 && errno == ERANGE);
    reset(18, 18);
    assert(RBXApplyMemoryBudget(NULL, 42, 256, &result) == -1);
    assert(RBXApplyMemoryBudget(mockControl, 42, 257, &result) == -1 && writes == 0 && reads == 0);
    puts("Memory budget tests passed");
}
