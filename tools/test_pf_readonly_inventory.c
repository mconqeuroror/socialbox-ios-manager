#define PF_INVENTORY_TESTING 1
#include "pf_readonly_inventory.c"
#include <assert.h>

struct fixture { const char *mode; unsigned statusReads,stateReads,anchorReads,rootRuleReads,calls; };
static int mode(struct fixture *f,const char *s) { return !strcmp(f->mode,s); }
static void put64(unsigned char *b,size_t n,uint64_t value) { memcpy(b+n,&value,8); }
static void putport(unsigned char *b,unsigned value) { uint16_t v=htons((uint16_t)value); memcpy(b,&v,2); }
static void fixture_state(unsigned char *b,unsigned af) {
    memset(b,0,PF_STATE_SIZE); memcpy(b,"STATE001",8); strcpy((char *)b+8,"en0");
    b[282]=b[283]=(unsigned char)af; b[284]=6; b[285]=2; b[288]=3;
    for(unsigned i=0;i<4;i++) { assert(inet_pton((int)af,af==AF_INET?"192.0.2.8":"2001:db8::42",b+24+24*i)==1); putport(b+40+24*i,443+i); }
    pf_put32(b,216,17); pf_put32(b,220,18); pf_put32(b,224,UINT32_MAX);
    put64(b,228,UINT64_C(0x100000007)); put64(b,236,500);
    pf_put32(b,244,2); pf_put32(b,248,3); pf_put32(b,252,4); pf_put32(b,256,5);
    pf_put32(b,260,6); pf_put32(b,264,7); pf_put32(b,268,8); pf_put32(b,272,9);
    // Values at the kernel-pointer slots must never appear in output.
    memset(b+200,0xad,16);
}
static int fixture_ioctl(void *ctx,unsigned long cmd,void *arg) {
    struct fixture *f=ctx; unsigned char *b=arg; f->calls++;
    if(mode(f,"permission")) { errno=EPERM; return -1; }
    if(cmd==PF_GET_STATUS) {
        memset(b,0,PF_STATUS_SIZE); pf_put32(b,376,mode(f,"status-invalid")?2:0); f->statusReads++;
        if(mode(f,"checksum-race")&&f->statusReads==2)b[424]=1;
        return 0;
    }
    if(cmd==PF_GET_RULES) {
        const char *path=(const char *)b+16; unsigned family=b[PF_RULE_OFFSET+1004];
        uint32_t count=!path[0]&&family==0&&!mode(f,"empty")?1:0;
        if(!path[0]&&family==0)f->rootRuleReads++;
        if(mode(f,"rules-bound")&&!path[0]&&family==0)count=PF_MAX_RULES+1;
        pf_put32(b,12,count); pf_put32(b,4,mode(f,"ticket-race")&&f->rootRuleReads>1?8:7); return 0;
    }
    if(cmd==PF_GET_RULE) {
        assert(pf_u32(b,0)==0);
        if(mode(f,"rule-busy")) { errno=EBUSY; return -1; }
        unsigned char *r=b+PF_RULE_OFFSET;
        strcpy((char *)r+192,"quote\"line\n"); strcpy((char *)r+256,"en0"); strcpy((char *)r+696,"diagnostic fixture");
        strcpy((char *)b+1040,"safe/nested");
        r[1004]=1; r[1005]=2; r[1008]=1; r[1012]=1; r[1013]=AF_INET; r[1014]=6;
        assert(inet_pton(AF_INET,"192.0.2.0",r)==1); assert(inet_pton(AF_INET,"255.255.255.0",r+16)==1);
        r[40]=0; putport(r+48,443); putport(r+50,8443); r[52]=4;
        r[104]=3; strcpy((char *)r+64,"allowed_destinations");
        pf_put32(r,976,501); pf_put32(r,980,502); r[984]=4;
        pf_put32(r,988,20); pf_put32(r,992,21); r[996]=4;
        put64(r,648,UINT64_C(0x100000003)); put64(r,656,123); put64(r,664,456);
        put64(r,672,789); put64(r,680,1011); pf_put32(r,904,12);
        memset(r+560,0xad,16); memset(r+768,0xad,24);
        if(mode(f,"rule-type"))r[40]=99;
        if(mode(f,"rule-af"))r[1013]=99;
        if(mode(f,"rule-string"))memset(r+192,'X',64);
        return 0;
    }
    if(cmd==PF_GET_ANCHORS) {
        const char *path=(const char *)b+4;
        unsigned count=mode(f,"empty")?0:(!path[0]||!strcmp(path,"safe"));
        if(mode(f,"anchor-bound"))count=PF_MAX_ANCHORS;
        if(mode(f,"anchor-depth"))count=1;
        pf_put32(b,0,count); return 0;
    }
    if(cmd==PF_GET_ANCHOR) {
        const char *path=(const char *)b+4; f->anchorReads++;
        strcpy((char *)b+1028,path[0]?"nested":"safe");
        if(mode(f,"anchor-depth"))strcpy((char *)b+1028,"deep");
        if(mode(f,"anchor-slash"))strcpy((char *)b+1028,"bad/path");
        if(mode(f,"anchor-dot"))strcpy((char *)b+1028,"..");
        if(mode(f,"anchor-string"))memset(b+1028,'X',64);
        if(mode(f,"anchor-race")&&f->anchorReads>=3)strcpy((char *)b+1028,"other");
        return 0;
    }
    if(cmd==PF_GET_STATES) {
        struct pf_states_request *q=arg; f->stateReads++;
        if(!q->length) {
            q->length=mode(f,"empty")?0:PF_STATE_SIZE*2;
            if(mode(f,"state-size-negative"))q->length=-1;
            if(mode(f,"state-size-misaligned"))q->length=1;
            if(mode(f,"state-size-bound"))q->length=PF_STATE_SIZE*(PF_MAX_STATES+1);
            if(mode(f,"state-race")&&f->stateReads==3)q->length=0;
            return 0;
        }
        int capacity=q->length;
        if(mode(f,"empty"))q->length=0;
        else {
            assert(capacity>=PF_STATE_SIZE*2);
            fixture_state(q->buffer,AF_INET); fixture_state((unsigned char *)q->buffer+PF_STATE_SIZE,AF_INET6); q->length=PF_STATE_SIZE*2;
        }
        if(mode(f,"state-return-negative"))q->length=-1;
        if(mode(f,"state-return-large"))q->length=capacity+1;
        if(mode(f,"state-return-misaligned"))q->length=1;
        if(mode(f,"state-truncated"))q->length=capacity;
        if(mode(f,"state-af"))((unsigned char *)q->buffer)[282]=99;
        if(mode(f,"state-string"))memset((unsigned char *)q->buffer+8,'X',16);
        return 0;
    }
    assert(!"unexpected ioctl reached fixture"); errno=ENOTTY; return -1;
}
int main(int argc,char **argv) {
    assert(argc==2); struct fixture f={.mode=argv[1]};
    struct pf_reader r={.read_ioctl=fixture_ioctl,.context=&f,.out=stdout,.started=pf_time()};
    if(mode(&f,"whitelist")) {
        struct pf_rule_bytes q={0}; unsigned long blocked[]={_IO('D',1),_IO('D',2),_IO('D',22),0,PF_GET_RULE^0x100UL};
        for(unsigned i=0;i<sizeof(blocked)/sizeof(blocked[0]);i++)assert(pf_query(&r,blocked[i],&q)<0);
        pf_put32(q.b,0,1); assert(pf_query(&r,PF_GET_RULE,&q)<0);
        assert(pf_query(&r,PF_GET_STATUS,NULL)<0); assert(f.calls==0);
        r.queries=PF_MAX_QUERIES; assert(pf_query(&r,PF_GET_STATUS,&q)<0); assert(f.calls==0);
        r.queries=0; r.started=pf_time()-21; assert(pf_query(&r,PF_GET_STATUS,&q)<0); assert(f.calls==0);
        return 0;
    }
    return pf_inspect(&r);
}
