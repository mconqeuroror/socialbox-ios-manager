#pragma once
#include <stdint.h>
#include <stddef.h>
#include <errno.h>

// Darwin memorystatus ABI (XNU kern_memorystatus.h). Limits are in MiB.
typedef struct {
    int32_t active;
    uint32_t activeAttributes;
    int32_t inactive;
    uint32_t inactiveAttributes;
} RBXMemoryLimits;
typedef int (*RBXMemoryControl)(uint32_t, int32_t, uint32_t, void *, size_t);

static inline int RBXApplyMemoryBudget(RBXMemoryControl control, int32_t pid,
                                      int32_t budget, RBXMemoryLimits *observed) {
    if (!control || pid <= 0 || budget <= 0 || budget > 256) { errno = EINVAL; return -1; }
    RBXMemoryLimits limits = {0};
    if (control(8, pid, 0, &limits, sizeof(limits)) != 0) return -1;
    int changed = 0;
    // Leave already larger or unlimited/default limits and kill attributes intact.
    if (limits.active > 0 && limits.active < budget) { limits.active = budget; changed = 1; }
    if (limits.inactive > 0 && limits.inactive < budget) { limits.inactive = budget; changed = 1; }
    if (changed && control(7, pid, 0, &limits, sizeof(limits)) != 0) return -1;
    if (control(8, pid, 0, &limits, sizeof(limits)) != 0) return -1;
    if (observed) *observed = limits;
    if ((limits.active > 0 && limits.active < budget) ||
        (limits.inactive > 0 && limits.inactive < budget)) { errno = ERANGE; return -1; }
    return 0;
}
