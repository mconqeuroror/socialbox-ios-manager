// Read-only platform capability probe. No rules, routes, preferences or packets written.
// Status ioctl ABI checked against Apple xnu-8796.121.2 bsd/net/pfvar.h:
// DIOCGETSTATUS is _IOWR('D', 21, pf_status), with a 440-byte arm64 record.
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/utsname.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
struct status_bytes { unsigned char value[440]; };
static uint32_t read_u32(const unsigned char *data, size_t offset) { uint32_t value=0; memcpy(&value, data+offset, sizeof(value)); return value; }
int main(void) {
  struct utsname u={0}; if(uname(&u)==0) printf("kernel=%s %s %s\n",u.sysname,u.release,u.version);
  printf("euid=%u abi_bytes=%zu ioctl=0x%lx\n",(unsigned)geteuid(),sizeof(struct status_bytes),(unsigned long)_IOWR('D',21,struct status_bytes));
  struct if_nameindex *names=if_nameindex(); if(names) {for(struct if_nameindex *p=names;p->if_index;p++) printf("interface=%s index=%u\n",p->if_name,p->if_index); if_freenameindex(names);}
  errno=0; int fd=open("/dev/pf",O_RDONLY|O_CLOEXEC); int saved=errno;
  printf("pf_open=%d errno=%d error=%s\n",fd<0?-1:0,saved,saved?strerror(saved):"none"); if(fd<0)return 2;
  struct status_bytes status={0}; errno=0; int result=ioctl(fd,_IOWR('D',21,struct status_bytes),&status); saved=errno;
  printf("pf_getstatus=%d errno=%d error=%s\n",result,saved,saved?strerror(saved):"none");
  if(result==0) printf("pf_running=%u pf_states=%u pf_source_nodes=%u\n",read_u32(status.value,376),read_u32(status.value,380),read_u32(status.value,384));
  close(fd); return result==0?0:3;
}
