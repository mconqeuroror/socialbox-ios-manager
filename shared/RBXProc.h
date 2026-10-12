#pragma once

#if __has_include(<libproc.h>)
#include <libproc.h>
#else
// Darwin libproc ABI used by the daemon and hooks. The iOS SDK omits libproc.h;
// these declarations match Apple's libproc.h and sys/proc_info.h.
#include <stdint.h>
#include <sys/param.h>
#define PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN)
#define PROC_PIDLISTFDS 1
#define PROX_FDTYPE_SOCKET 2
struct proc_fdinfo { int32_t proc_fd; uint32_t proc_fdtype; };
#ifdef __cplusplus
extern "C" {
#endif
int proc_listallpids(void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#ifdef __cplusplus
}
#endif
#endif
