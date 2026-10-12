#define NETWORK_PROBE_TESTING 1
#include "network_readonly_probe.c"
#include <assert.h>
static unsigned checks;
#define CHECK(x) do { assert(x); checks++; } while(0)
static void put16(unsigned char *b,uint16_t n) { memcpy(b,&n,2); }
static void put32(unsigned char *b,uint32_t n) { memcpy(b,&n,4); }
static size_t route(unsigned char *b,int family,unsigned flags) {
    memset(b,0,160); size_t size=family==AF_INET?16:28,n=92+size+4;
    put16(b,(uint16_t)n); b[2]=5; put16(b+4,1); put32(b+8,flags); put32(b+12,5);
    b[92]=(unsigned char)size; b[93]=(unsigned char)family; // zero destination + zero-length mask
    return n;
}
static int decode(FILE *f,unsigned char *b,size_t n,struct net_counts *c) { memset(c,0,sizeof(*c)); return net_route_records(f,b,n,c); }
int main(void) {
    (void)&net_interfaces; (void)&net_routes;
    FILE *out=tmpfile(); assert(out); unsigned char b[160]; struct net_counts c; size_t n;
    n=route(b,AF_INET,1); CHECK(decode(out,b,n,&c)==0); CHECK(c.defaults4==1&&c.usable4==1&&c.routes==1);
    n=route(b,AF_INET6,1|RBX_RTF_IFSCOPE); CHECK(decode(out,b,n,&c)==0); CHECK(c.defaults6==1&&c.usable6==1);
    n=route(b,AF_INET,0); CHECK(decode(out,b,n,&c)==0&&c.defaults4==1&&c.usable4==0);
    n=route(b,AF_INET,1|RBX_RTF_REJECT); CHECK(decode(out,b,n,&c)==0&&c.defaults4==1&&c.usable4==0);
    n=route(b,AF_INET,1|RBX_RTF_BLACKHOLE); CHECK(decode(out,b,n,&c)==0&&c.defaults4==1&&c.usable4==0);
    n=route(b,AF_INET,1|RBX_RTF_HOST); CHECK(decode(out,b,n,&c)==0&&c.defaults4==0);
    n=route(b,AF_INET,1); b[96]=192; CHECK(decode(out,b,n,&c)==0&&c.defaults4==0);
    n=route(b,AF_INET,1); b[108]=4; b[110]=255; CHECK(decode(out,b,n,&c)==0&&c.defaults4==0);
    n=route(b,AF_INET,1); b[2]=4; CHECK(decode(out,b,n,&c)<0);
    n=route(b,AF_INET,1); put16(b,0); CHECK(decode(out,b,n,&c)<0);
    n=route(b,AF_INET,1); put16(b,(uint16_t)n+1); CHECK(decode(out,b,n,&c)<0);
    n=route(b,AF_INET,1); put32(b+12,256); CHECK(decode(out,b,n,&c)<0);
    n=route(b,AF_INET,1); b[92]=1; CHECK(decode(out,b,n,&c)<0);
    n=route(b,AF_INET,1); b[92]=255; CHECK(decode(out,b,n,&c)<0);
    n=route(b,AF_INET,1); CHECK(decode(out,b,91,&c)<0);
    n=route(b,AF_INET,1); CHECK(decode(out,b,n-1,&c)<0);
    CHECK(decode(out,b,0,&c)==0&&c.routes==0);
    unsigned char address[16];
    const char *ipv4[][2]={{"127.0.0.1","loopback"},{"169.254.1.2","link-local"},{"192.168.1.2","private"},{"172.16.0.1","private"},{"172.31.1.1","private"},{"172.32.1.1","other-unicast"},{"10.0.0.1","private"},{"100.64.0.1","shared-CGNAT"},{"100.128.0.1","other-unicast"},{"0.0.0.0","unspecified-or-reserved"},{"224.0.0.1","multicast-or-reserved"}};
    for(unsigned i=0;i<sizeof(ipv4)/sizeof(ipv4[0]);i++) { CHECK(inet_pton(AF_INET,ipv4[i][0],address)==1); CHECK(!strcmp(net_scope(AF_INET,address),ipv4[i][1])); }
    const char *ipv6[][2]={{"::","unspecified"},{"::1","loopback"},{"fe80::1","link-local"},{"fd00::1","unique-local"},{"2001:db8::1","global-unicast"},{"ff02::1","other"}};
    for(unsigned i=0;i<sizeof(ipv6)/sizeof(ipv6[0]);i++) { CHECK(inet_pton(AF_INET6,ipv6[i][0],address)==1); CHECK(!strcmp(net_scope(AF_INET6,address),ipv6[i][1])); }
    // Every prefix truncation is bounded, regardless of decoder result.
    n=route(b,AF_INET6,1); for(size_t i=1;i<n;i++)CHECK(decode(out,b,i,&c)<0);
    fclose(out); printf("PASS: %u read-only route/interface classification checks (host; no network access)\n",checks);
    return 0;
}
