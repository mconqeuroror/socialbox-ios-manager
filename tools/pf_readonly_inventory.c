// Standalone diagnostic, not a firewall backend. No policy or state writes.
// ABI: Apple xnu-8796.121.2 / xnu-8796.141.3 bsd/net/pfvar.h (identical).
// Fixed-size byte records deliberately never serialize kernel pointer fields.
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/utsname.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { PF_STATUS_SIZE=440, PF_RULE_SIZE=3104, PF_RULE_OFFSET=2064,
       PF_ANCHOR_SIZE=1092, PF_STATE_SIZE=297,
       PF_MAX_ANCHORS=128, PF_MAX_DEPTH=12, PF_MAX_RULES=4096,
       PF_MAX_STATES=16384, PF_MAX_QUERIES=12000 };
struct pf_status_bytes { unsigned char b[PF_STATUS_SIZE]; };
struct pf_rule_bytes { unsigned char b[PF_RULE_SIZE]; };
struct pf_anchor_bytes { unsigned char b[PF_ANCHOR_SIZE]; };
struct pf_states_request { int32_t length; uint32_t padding; void *buffer; };
#define PF_GET_STATUS _IOWR('D',21,struct pf_status_bytes)
#define PF_GET_RULES _IOWR('D',6,struct pf_rule_bytes)
#define PF_GET_RULE _IOWR('D',7,struct pf_rule_bytes)
#define PF_GET_ANCHORS _IOWR('D',58,struct pf_anchor_bytes)
#define PF_GET_ANCHOR _IOWR('D',59,struct pf_anchor_bytes)
#define PF_GET_STATES _IOWR('D',25,struct pf_states_request)
_Static_assert(sizeof(void *)==8,"arm64/64-bit ABI required");
_Static_assert(sizeof(struct pf_states_request)==16,"pfioc_states size");
_Static_assert(offsetof(struct pf_states_request,buffer)==8,"pfioc_states pointer");
_Static_assert(PF_GET_STATUS==0xc1b84415UL,"status ioctl");
_Static_assert(PF_GET_RULES==0xcc204406UL,"rules ioctl");
_Static_assert(PF_GET_RULE==0xcc204407UL,"rule ioctl");
_Static_assert(PF_GET_ANCHORS==0xc444443aUL,"anchors ioctl");
_Static_assert(PF_GET_ANCHOR==0xc444443bUL,"anchor ioctl");
_Static_assert(PF_GET_STATES==0xc0104419UL,"states ioctl");

struct pf_reader {
    int (*read_ioctl)(void *,unsigned long,void *);
    void *context;
    FILE *out;
    unsigned anchors,rules,states,queries,errors;
    double started;
};
static uint32_t pf_u32(const unsigned char *b,size_t n) { uint32_t v; memcpy(&v,b+n,4); return v; }
static uint64_t pf_u64(const unsigned char *b,size_t n) { uint64_t v; memcpy(&v,b+n,8); return v; }
static void pf_put32(unsigned char *b,size_t n,uint32_t v) { memcpy(b+n,&v,4); }
static uint16_t pf_port(const unsigned char *b) { uint16_t v; memcpy(&v,b,2); return ntohs(v); }
static double pf_time(void) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) return 0; return t.tv_sec+t.tv_nsec/1e9; }
static void pf_string(FILE *out,const char *s,size_t capacity) {
    fputc('"',out);
    for(size_t i=0;i<capacity && s[i];i++) {
        unsigned char c=(unsigned char)s[i];
        if(c=='"'||c=='\\') { fputc('\\',out); fputc(c,out); }
        else if(c<32||c>=127) fprintf(out,"\\u%04x",c);
        else fputc(c,out);
    }
    fputc('"',out);
}
static void pf_hex(FILE *out,const unsigned char *b,size_t n) { fputc('"',out); for(size_t i=0;i<n;i++)fprintf(out,"%02x",b[i]); fputc('"',out); }
static int pf_error(struct pf_reader *r,const char *operation,int code) {
    r->errors++; fputs("{\"record\":\"error\",\"operation\":",r->out); pf_string(r->out,operation,128);
    fprintf(r->out,",\"errno\":%d}\n",code); return -1;
}
// O_RDONLY is NOT the write boundary: XNU admits some mutating ioctls on it.
// GETRULE with PF_GET_CLR_CNTR=1 also mutates despite its innocent command name.
static int pf_query(struct pf_reader *r,unsigned long cmd,void *arg) {
    if(!arg || !(cmd==PF_GET_STATUS||cmd==PF_GET_RULES||cmd==PF_GET_RULE||
                 cmd==PF_GET_ANCHORS||cmd==PF_GET_ANCHOR||cmd==PF_GET_STATES))
        return pf_error(r,"non-read ioctl rejected",EPERM);
    if(cmd==PF_GET_RULE && pf_u32(arg,0)!=0) return pf_error(r,"counter reset rejected",EPERM);
    if(r->queries>=PF_MAX_QUERIES || pf_time()-r->started>20.0)
        return pf_error(r,"inspection budget",ETIMEDOUT);
    r->queries++;
    if(r->read_ioctl(r->context,cmd,arg)<0) {
        int saved=errno; char op[40]; snprintf(op,sizeof(op),"ioctl 0x%lx",cmd); return pf_error(r,op,saved);
    }
    return 0;
}
static int pf_text_valid(const unsigned char *s,size_t n) { return memchr(s,0,n)!=NULL; }
static int pf_address(FILE *out,const unsigned char *address,unsigned af) {
    char text[INET6_ADDRSTRLEN];
    if(af!=AF_INET && af!=AF_INET6) { fputs("null",out); return af==0?0:-1; }
    if(!inet_ntop((int)af,address,text,sizeof(text))) { fputs("null",out); return -1; }
    pf_string(out,text,sizeof(text)); return 0;
}
static int pf_rule_address(struct pf_reader *r,const unsigned char *b,unsigned af) {
    FILE *out=r->out; unsigned type=b[40];
    fprintf(out,"{\"type\":%u,\"interfaceFlags\":%u,\"negated\":%u,\"portOperator\":%u,\"portLow\":%u,\"portHigh\":%u",
            type,b[41],b[56],b[52],pf_port(b+48),pf_port(b+50));
    int valid=type<=6;
    if(type==0 || type==6) {
        fputs(",\"address\":",out); if(pf_address(out,b,af))valid=0;
        fputs(",\"maskOrRangeEnd\":",out); if(pf_address(out,b+16,af))valid=0;
        fputs(",\"addressBytes\":",out); pf_hex(out,b,32);
    } else if(type==2 || type==3 || type==4) {
        size_t length=type==2?16:32; if(!pf_text_valid(b,length))valid=0;
        fputs(",\"name\":",out); pf_string(out,(const char *)b,length);
    }
    fputc('}',out); return valid?0:-1;
}
static int pf_emit_rule(struct pf_reader *r,const char *path,unsigned family,unsigned nr,const unsigned char *record) {
    const unsigned char *b=record+PF_RULE_OFFSET; FILE *out=r->out; int valid=1;
    const size_t strings[][2]={{192,64},{256,16},{272,64},{336,64},{400,64},{464,64},{528,32},{696,64}};
    for(size_t i=0;i<sizeof(strings)/sizeof(strings[0]);i++) if(!pf_text_valid(b+strings[i][0],strings[i][1]))valid=0;
    if(!pf_text_valid(record+1040,1024))valid=0;
    fputs("{\"record\":\"rule\",\"anchor\":",out); pf_string(out,path,1024);
    fprintf(out,",\"familyAction\":%u,\"number\":%u,\"anchorCall\":",family,nr); pf_string(out,(const char *)record+1040,1024);
    const char *names[]={"label","interface","queue","parentQueue","tag","matchTag","overloadTable","owner"};
    for(size_t i=0;i<sizeof(strings)/sizeof(strings[0]);i++) {
        fprintf(out,",\"%s\":",names[i]); pf_string(out,(const char *)b+strings[i][0],strings[i][1]);
    }
    fprintf(out,",\"priority\":%u,\"flags\":%u,\"evaluations\":%" PRIu64 ",\"packets\":[%" PRIu64 ",%" PRIu64 "],\"bytes\":[%" PRIu64 ",%" PRIu64 "],\"states\":%u",
            pf_u32(b,760),pf_u32(b,1000),pf_u64(b,648),pf_u64(b,656),pf_u64(b,664),pf_u64(b,672),pf_u64(b,680),pf_u32(b,904));
    fprintf(out,",\"uid\":{\"low\":%u,\"high\":%u,\"operator\":%u},\"gid\":{\"low\":%u,\"high\":%u,\"operator\":%u}",
            pf_u32(b,976),pf_u32(b,980),b[984],pf_u32(b,988),pf_u32(b,992),b[996]);
    const char *scalars[]={"action","direction","log","logInterface","quick","interfaceNegated","matchTagNegated","natPass","keepState","addressFamily","protocol","icmpType","icmpCode","tcpFlags","tcpFlagSet","minTTL","allowOptions","routeType","returnTTL","tos","anchorRelative","anchorWildcard","flush","protocolVariant","externalFilter","externalMap"};
    for(size_t i=0;i<sizeof(scalars)/sizeof(scalars[0]);i++) fprintf(out,",\"%s\":%u",scalars[i],b[1004+i]);
    fprintf(out,",\"dummynetPipe\":%u,\"dummynetType\":%u,\"source\":",pf_u32(b,1032),pf_u32(b,1036));
    if(pf_rule_address(r,b,b[1013]))valid=0;
    fputs(",\"destination\":",out); if(pf_rule_address(r,b+64,b[1013]))valid=0;
    fputs(",\"semanticExpansionComplete\":false}\n",out);
    r->rules++; return valid?0:pf_error(r,"rule field ABI validation",EPROTO);
}
static void pf_rule_request(struct pf_rule_bytes *request,const char *path,unsigned family) {
    memset(request,0,sizeof(*request)); memcpy(request->b+16,path,strlen(path)+1); request->b[PF_RULE_OFFSET+1004]=(unsigned char)family;
}
static int pf_rules(struct pf_reader *r,const char *path,unsigned family) {
    struct pf_rule_bytes q; pf_rule_request(&q,path,family);
    if(pf_query(r,PF_GET_RULES,&q))return -1;
    uint32_t count=pf_u32(q.b,12),ticket=pf_u32(q.b,4);
    if(count>PF_MAX_RULES-r->rules)return pf_error(r,"rule count bound",EOVERFLOW);
    fputs("{\"record\":\"ruleset\",\"anchor\":",r->out); pf_string(r->out,path,1024);
    fprintf(r->out,",\"familyAction\":%u,\"count\":%u,\"ticket\":%u}\n",family,count,ticket);
    for(uint32_t i=0;i<count;i++) {
        pf_rule_request(&q,path,family); pf_put32(q.b,4,ticket); pf_put32(q.b,12,i);
        if(pf_query(r,PF_GET_RULE,&q)||pf_emit_rule(r,path,family,i,q.b))return -1;
    }
    pf_rule_request(&q,path,family); if(pf_query(r,PF_GET_RULES,&q))return -1;
    if(count!=pf_u32(q.b,12)||ticket!=pf_u32(q.b,4))return pf_error(r,"ruleset changed during inspection",EAGAIN);
    return 0;
}
static void pf_anchor_request(struct pf_anchor_bytes *q,const char *path,unsigned nr) {
    memset(q,0,sizeof(*q)); pf_put32(q->b,0,nr); memcpy(q->b+4,path,strlen(path)+1);
}
static int pf_anchors(struct pf_reader *r,const char *path,unsigned depth) {
    if(depth>PF_MAX_DEPTH||r->anchors>=PF_MAX_ANCHORS)return pf_error(r,"anchor traversal bound",EOVERFLOW);
    r->anchors++; fputs("{\"record\":\"anchor\",\"path\":",r->out); pf_string(r->out,path,1024); fputs("}\n",r->out);
    // scrub, filter, NAT, BINAT, RDR (also NAT64), dummynet. Every ruleset.
    const unsigned families[]={2,0,4,6,8,11};
    for(size_t i=0;i<sizeof(families)/sizeof(families[0]);i++)if(pf_rules(r,path,families[i]))return -1;
    struct pf_anchor_bytes q; pf_anchor_request(&q,path,0); if(pf_query(r,PF_GET_ANCHORS,&q))return -1;
    unsigned count=pf_u32(q.b,0); if(count>PF_MAX_ANCHORS-r->anchors)return pf_error(r,"child anchor count bound",EOVERFLOW);
    char (*names)[64]=calloc(count?count:1,64); if(!names)return pf_error(r,"anchor allocation",ENOMEM);
    int result=-1;
    for(unsigned i=0;i<count;i++) {
        pf_anchor_request(&q,path,i); if(pf_query(r,PF_GET_ANCHOR,&q))goto done;
        const char *name=(const char *)q.b+1028;
        if(!pf_text_valid(q.b+1028,64)||!name[0]||strchr(name,'/')||!strcmp(name,".")||!strcmp(name,"..")) { pf_error(r,"invalid anchor name",EPROTO); goto done; }
        memcpy(names[i],name,strlen(name)+1);
        for(unsigned j=0;j<i;j++)if(!strcmp(names[i],names[j])) { pf_error(r,"duplicate anchor",EAGAIN); goto done; }
        char child[1024]; int n=snprintf(child,sizeof(child),"%s%s%s",path,path[0]?"/":"",name);
        if(n<0||(size_t)n>=sizeof(child)) { pf_error(r,"anchor path bound",ENAMETOOLONG); goto done; }
        if(pf_anchors(r,child,depth+1))goto done;
    }
    pf_anchor_request(&q,path,0); if(pf_query(r,PF_GET_ANCHORS,&q))goto done;
    if(pf_u32(q.b,0)!=count) { pf_error(r,"anchor count changed",EAGAIN); goto done; }
    for(unsigned i=0;i<count;i++) {
        pf_anchor_request(&q,path,i); if(pf_query(r,PF_GET_ANCHOR,&q))goto done;
        if(!pf_text_valid(q.b+1028,64)||strcmp(names[i],(const char *)q.b+1028)) { pf_error(r,"anchor names changed",EAGAIN); goto done; }
    }
    result=0;
done: free(names); return result;
}
static uint64_t pf_state_counter(const unsigned char *b,size_t n) { return ((uint64_t)pf_u32(b,n)<<32)|pf_u32(b,n+4); }
static int pf_emit_state(struct pf_reader *r,const unsigned char *b) {
    FILE *out=r->out; int valid=pf_text_valid(b+8,16) && (b[282]==AF_INET||b[282]==AF_INET6) && (b[283]==AF_INET||b[283]==AF_INET6);
    fputs("{\"record\":\"state\",\"idBytes\":",out); pf_hex(out,b,8); fputs(",\"interface\":",out); pf_string(out,(const char *)b+8,16);
    fprintf(out,",\"protocol\":%u,\"direction\":%u,\"lanFamily\":%u,\"gatewayFamily\":%u",b[284],b[285],b[282],b[283]);
    const char *names[]={"lan","gateway","externalLAN","externalGateway"};
    for(unsigned i=0;i<4;i++) {
        size_t offset=24+24*i; fprintf(out,",\"%s\":{\"address\":",names[i]);
        if(pf_address(out,b+offset,b[(i%2)?283:282]))valid=0;
        fprintf(out,",\"portOrId\":%u,\"transportBytes\":",pf_port(b+offset+16)); pf_hex(out,b+offset+16,4); fputc('}',out);
    }
    fprintf(out,",\"rule\":%u,\"anchorRule\":%u,\"natRule\":%u,\"ageSeconds\":%" PRIu64 ",\"expiresInSeconds\":%" PRIu64 ",\"packets\":[%" PRIu64 ",%" PRIu64 "],\"bytes\":[%" PRIu64 ",%" PRIu64 "],\"timeout\":%u}\n",
            pf_u32(b,216),pf_u32(b,220),pf_u32(b,224),pf_u64(b,228),pf_u64(b,236),pf_state_counter(b,244),pf_state_counter(b,252),pf_state_counter(b,260),pf_state_counter(b,268),b[288]);
    r->states++; return valid?0:pf_error(r,"state field ABI validation",EPROTO);
}
static int pf_states(struct pf_reader *r) {
    struct pf_states_request q={0}; if(pf_query(r,PF_GET_STATES,&q))return -1;
    if(q.length<0||q.length%PF_STATE_SIZE||q.length/PF_STATE_SIZE>PF_MAX_STATES)return pf_error(r,"state size bound or ABI",EPROTO);
    // One record slack detects growth/truncation, including initial zero states.
    int32_t capacity=q.length+PF_STATE_SIZE; unsigned char *storage=calloc(1,(size_t)capacity);
    if(!storage)return pf_error(r,"state allocation",ENOMEM);
    q.length=capacity; q.buffer=storage; int result=-1;
    if(pf_query(r,PF_GET_STATES,&q))goto done;
    if(q.length<0||q.length>capacity||q.length%PF_STATE_SIZE) { pf_error(r,"invalid returned state size",EPROTO); goto done; }
    if(q.length==capacity) { pf_error(r,"state snapshot may be truncated",EAGAIN); goto done; }
    int32_t returned=q.length;
    for(int32_t i=0;i<returned;i+=PF_STATE_SIZE)if(pf_emit_state(r,storage+i))goto done;
    q=(struct pf_states_request){0}; if(pf_query(r,PF_GET_STATES,&q))goto done;
    if(q.length!=returned) { pf_error(r,"state count changed",EAGAIN); goto done; }
    result=0;
done: free(storage); return result;
}
static void pf_emit_status(struct pf_reader *r,const char *phase,const unsigned char *b) {
    fprintf(r->out,"{\"record\":\"status\",\"phase\":\"%s\",\"running\":%u,\"states\":%u,\"sourceNodes\":%u,\"rulesChecksum\":",phase,pf_u32(b,376),pf_u32(b,380),pf_u32(b,384)); pf_hex(r->out,b+424,16); fputs("}\n",r->out);
}
static int pf_inspect(struct pf_reader *r) {
    r->started=pf_time();
    fputs("{\"record\":\"inventory\",\"schema\":1,\"abi\":\"Apple-xnu-8796-64bit\",\"readOnly\":true,\"atomicSnapshot\":false,\"enforcementVerified\":false,\"semanticExpansionComplete\":false,\"limitations\":[\"dynamic address table entries and route/NAT pool members are not expanded\",\"same-count concurrent state changes are not detectable\",\"not an installable or restorable policy dump\"]}\n",r->out);
    struct pf_status_bytes before={0},after={0};
    if(pf_query(r,PF_GET_STATUS,&before))goto done;
    pf_emit_status(r,"before",before.b);
    if(pf_u32(before.b,376)>1) { pf_error(r,"status ABI validation",EPROTO); goto done; }
    (void)pf_anchors(r,"",0);
    (void)pf_states(r);
    if(pf_query(r,PF_GET_STATUS,&after))goto done;
    pf_emit_status(r,"after",after.b);
    if(pf_u32(before.b,376)!=pf_u32(after.b,376)||memcmp(before.b+424,after.b+424,16))pf_error(r,"policy changed during inspection",EAGAIN);
done:
    fprintf(r->out,"{\"record\":\"summary\",\"enumerationComplete\":%s,\"anchors\":%u,\"rules\":%u,\"states\":%u,\"queries\":%u,\"errors\":%u,\"enforcementVerified\":false}\n",r->errors?"false":"true",r->anchors,r->rules,r->states,r->queries,r->errors);
    if(ferror(r->out))return 3;
    return r->errors?2:0;
}
#ifndef PF_INVENTORY_TESTING
static int pf_real_ioctl(void *context,unsigned long cmd,void *argument) { return ioctl(*(int *)context,cmd,argument); }
int main(int argc,char **argv) {
    (void)argv;
    if(argc!=1) { fputs("No arguments supported; read-only inspection only.\n",stderr); return 64; }
    struct utsname u={0};
    if(uname(&u)||strcmp(u.release,"22.6.0")||!strstr(u.version,"xnu-8796.142.1.703.8")||geteuid()!=0) {
        fputs("Requires root and observed Darwin22.6.0/XNU8796.142.1.703.8 ABI; no query performed.\n",stderr); return 65;
    }
    int fd=open("/dev/pf",O_RDONLY|O_CLOEXEC);
    if(fd<0) { fprintf(stderr,"Cannot open /dev/pf read-only: errno=%d\n",errno); return 66; }
    struct pf_reader r={.read_ioctl=pf_real_ioctl,.context=&fd,.out=stdout};
    int result=pf_inspect(&r); close(fd); return result;
}
#endif
