// Interface/default-route observation only: no sockets, DNS, radio or route writes.
// Routing message ABI measured against Apple xnu-8796.141.3 route.h/rtsock.c.
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
enum { RBX_ROUTE_HEADER=92, RBX_ROUTE_VERSION=5, RBX_RTF_UP=1, RBX_RTF_HOST=4,
       RBX_RTF_REJECT=8, RBX_RTF_BLACKHOLE=0x1000, RBX_RTF_IFSCOPE=0x1000000 };
static uint16_t net_u16(const unsigned char *b) { uint16_t n; memcpy(&n,b,2); return n; }
static uint32_t net_u32(const unsigned char *b) { uint32_t n; memcpy(&n,b,4); return n; }
static void net_string(FILE *out,const char *s,size_t bound) {
    fputc('"',out); for(size_t i=0;i<bound&&s[i];i++) {
        unsigned char c=(unsigned char)s[i];
        if(c=='"'||c=='\\') { fputc('\\',out); fputc(c,out); }
        else if(c<32||c>=127)fprintf(out,"\\u%04x",c); else fputc(c,out);
    } fputc('"',out);
}
static int net_zero(const unsigned char *b,size_t n) { for(size_t i=0;i<n;i++)if(b[i])return 0; return 1; }
// No inference of Internet access: private/ULA addresses may route through NAT.
static const char *net_scope(int family,const unsigned char *b) {
    if(family==AF_INET) {
        if(b[0]==0)return "unspecified-or-reserved";
        if(b[0]==127)return "loopback";
        if(b[0]==169&&b[1]==254)return "link-local";
        if(b[0]>=224)return "multicast-or-reserved";
        if(b[0]==10||(b[0]==172&&b[1]>=16&&b[1]<=31)||(b[0]==192&&b[1]==168))return "private";
        if(b[0]==100&&b[1]>=64&&b[1]<=127)return "shared-CGNAT";
        return "other-unicast";
    }
    if(net_zero(b,16))return "unspecified";
    if(net_zero(b,15)&&b[15]==1)return "loopback";
    if(b[0]==0xfe&&(b[1]&0xc0)==0x80)return "link-local";
    if((b[0]&0xfe)==0xfc)return "unique-local";
    if((b[0]&0xe0)==0x20)return "global-unicast";
    return "other";
}
struct net_counts { unsigned ipv4,ipv6,up4,up6,global6,defaults4,defaults6,usable4,usable6,routes; };
static int net_interfaces(FILE *out,struct net_counts *counts) {
    struct ifaddrs *first=NULL;
    if(getifaddrs(&first)) { fprintf(out,"{\"record\":\"error\",\"operation\":\"getifaddrs\",\"errno\":%d}\n",errno); return -1; }
    unsigned total=0,seen=0; char interfaceNames[128][IF_NAMESIZE]={0};
    for(struct ifaddrs *p=first;p;p=p->ifa_next) {
        if(++total>4096) { freeifaddrs(first); return -1; }
        if(!p->ifa_name)continue;
        unsigned flags=p->ifa_flags; int known=0;
        for(unsigned i=0;i<seen;i++)if(!strncmp(interfaceNames[i],p->ifa_name,IF_NAMESIZE))known=1;
        if(!known) {
            if(seen>=128||strnlen(p->ifa_name,IF_NAMESIZE)==IF_NAMESIZE) { freeifaddrs(first); return -1; }
            memcpy(interfaceNames[seen++],p->ifa_name,strlen(p->ifa_name)+1);
            fputs("{\"record\":\"interface\",\"name\":",out); net_string(out,p->ifa_name,IF_NAMESIZE);
            fprintf(out,",\"flags\":%u,\"up\":%s,\"running\":%s,\"loopback\":%s}\n",flags,flags&IFF_UP?"true":"false",flags&IFF_RUNNING?"true":"false",flags&IFF_LOOPBACK?"true":"false");
        }
        if(!p->ifa_addr)continue;
        int family=p->ifa_addr->sa_family;
        if(family!=AF_INET&&family!=AF_INET6)continue; // Never output link-layer/MAC identifiers.
        const void *addr=family==AF_INET?(const void *)&((struct sockaddr_in *)p->ifa_addr)->sin_addr:(const void *)&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
        char address[INET6_ADDRSTRLEN]; if(!inet_ntop(family,addr,address,sizeof(address)))continue;
        const char *scope=net_scope(family,addr);
        int active=(flags&IFF_UP)&&(flags&IFF_RUNNING)&&!(flags&IFF_LOOPBACK);
        if(family==AF_INET) { counts->ipv4++; if(active&&strcmp(scope,"link-local")&&strcmp(scope,"loopback")&&strcmp(scope,"unspecified-or-reserved")&&strcmp(scope,"multicast-or-reserved"))counts->up4++; }
        else { counts->ipv6++; if(active&&(!strcmp(scope,"unique-local")||!strcmp(scope,"global-unicast")))counts->up6++; if(active&&!strcmp(scope,"global-unicast"))counts->global6++; }
        fputs("{\"record\":\"interfaceAddress\",\"interface\":",out); net_string(out,p->ifa_name,IF_NAMESIZE);
        fprintf(out,",\"family\":%d,\"flags\":%u,\"up\":%s,\"running\":%s,\"loopback\":%s,\"address\":",family,flags,flags&IFF_UP?"true":"false",flags&IFF_RUNNING?"true":"false",flags&IFF_LOOPBACK?"true":"false");
        net_string(out,address,sizeof(address)); fputs(",\"scope\":",out); net_string(out,scope,40); fputs("}\n",out);
    }
    freeifaddrs(first); return 0;
}
static int net_route_records(FILE *out,const unsigned char *bytes,size_t length,struct net_counts *counts) {
    size_t offset=0;
    while(offset<length) {
        if(length-offset<RBX_ROUTE_HEADER)return -1;
        const unsigned char *b=bytes+offset; unsigned n=net_u16(b); uint32_t flags=net_u32(b+8),bits=net_u32(b+12);
        if(n<RBX_ROUTE_HEADER||n>length-offset||b[2]!=RBX_ROUTE_VERSION||(bits&~255U))return -1;
        const unsigned char *fields[8]={0}; size_t cursor=RBX_ROUTE_HEADER;
        for(unsigned i=0;i<8;i++)if(bits&(1U<<i)) {
            if(cursor+2>n)return -1;
            unsigned size=b[cursor]; size_t padded=size?((size+3U)&~3U):4U;
            if(size==1||padded>n-cursor)return -1;
            fields[i]=b+cursor; cursor+=padded;
        }
        if(++counts->routes>65536)return -1;
        const unsigned char *dst=fields[0],*mask=fields[2]; int family=dst?dst[1]:0;
        size_t start=family==AF_INET?4:8,addrsize=family==AF_INET?4:16;
        int isdefault=dst&&(family==AF_INET||family==AF_INET6)&&dst[0]>=start+addrsize&&net_zero(dst+start,addrsize)&&!(flags&RBX_RTF_HOST)&&mask&&(mask[0]==0||(mask[0]>=2&&net_zero(mask+2,mask[0]-2)));
        if(isdefault) {
            int usable=(flags&RBX_RTF_UP)&&!(flags&(RBX_RTF_REJECT|RBX_RTF_BLACKHOLE));
            if(family==AF_INET) { counts->defaults4++; if(usable)counts->usable4++; }
            else { counts->defaults6++; if(usable)counts->usable6++; }
            char name[IF_NAMESIZE]={0}; unsigned index=net_u16(b+4); if_indextoname(index,name);
            fprintf(out,"{\"record\":\"defaultRoute\",\"family\":%d,\"interfaceIndex\":%u,\"interface\":",family,index); net_string(out,name,sizeof(name));
            fprintf(out,",\"flags\":%u,\"upWithoutRejectOrBlackhole\":%s,\"interfaceScoped\":%s}\n",flags,usable?"true":"false",flags&RBX_RTF_IFSCOPE?"true":"false");
        }
        offset+=n;
    }
    return 0;
}
static int net_routes(FILE *out,struct net_counts *counts) {
    int mib[]={CTL_NET,PF_ROUTE,0,AF_UNSPEC,NET_RT_DUMP,0}; size_t length=0;
    // Explicit NULL newp/newlen=0 for both sysctl calls: never writes a route.
    if(sysctl(mib,6,NULL,&length,NULL,0))goto error;
    if(length>4*1024*1024) { errno=EOVERFLOW; goto error; }
    if(!length)return 0;
    unsigned char *buffer=malloc(length); if(!buffer)goto error;
    size_t capacity=length;
    if(sysctl(mib,6,buffer,&length,NULL,0)) { int code=errno; free(buffer); errno=code; goto error; }
    if(length>capacity||net_route_records(out,buffer,length,counts)) { free(buffer); errno=EPROTO; goto error; }
    free(buffer); return 0;
error: fprintf(out,"{\"record\":\"error\",\"operation\":\"read route table\",\"errno\":%d}\n",errno); return -1;
}
#ifndef NETWORK_PROBE_TESTING
int main(int argc,char **argv) {
    (void)argv; struct utsname u={0};
    if(argc!=1||uname(&u)||strcmp(u.release,"22.6.0")||!strstr(u.version,"xnu-8796.142.1.703.8")) { fputs("Requires observed Darwin22.6.0/XNU8796.142.1.703.8; no arguments.\n",stderr); return 64; }
    struct net_counts counts={0}; int interfaces=net_interfaces(stdout,&counts),routes=net_routes(stdout,&counts);
    fprintf(stdout,"{\"record\":\"summary\",\"readOnly\":true,\"interfaceReadComplete\":%s,\"routeReadComplete\":%s,\"ipv4Addresses\":%u,\"ipv6Addresses\":%u,\"upNonLinkLocalIPv4\":%u,\"upNonLinkLocalIPv6\":%u,\"upGlobalIPv6\":%u,\"ipv4DefaultRoutes\":%u,\"ipv6DefaultRoutes\":%u,\"upIPv4DefaultWithoutRejectOrBlackhole\":%u,\"upIPv6DefaultWithoutRejectOrBlackhole\":%u,\"routesInspected\":%u,\"internetReachabilityTested\":false,\"dnsTested\":false}\n",interfaces?"false":"true",routes?"false":"true",counts.ipv4,counts.ipv6,counts.up4,counts.up6,counts.global6,counts.defaults4,counts.defaults6,counts.usable4,counts.usable6,counts.routes);
    return interfaces||routes?2:0;
}
#endif
