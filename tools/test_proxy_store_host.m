#import "../lucid/Manager/SBProxyStore.m"

static int fail = 0;
static void expect(int ok, const char *msg) {
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", msg);
        fail = 1;
    }
}

int main(void) {
    SBProxyStore *store = [SBProxyStore new];
    SBProxyRecord *a = [store parseLine:@"1.2.3.4:1080"];
    expect(a && [a.host isEqual:@"1.2.3.4"] && [a.port isEqual:@"1080"] && [a.protocol isEqual:@"socks5"],
           "schemeless host:port");
    SBProxyRecord *b = [store parseLine:@"http://u:p@10.0.0.1:8080"];
    expect(b && [b.protocol isEqual:@"http"] && [b.user isEqual:@"u"] && [b.password isEqual:@"p"], "http url");
    SBProxyRecord *c = [store parseLine:@"socks5://proxy.local:9050"];
    expect(c && [c.protocol isEqual:@"socks5"] && [c.host isEqual:@"proxy.local"], "socks5 url");
    SBProxyRecord *d = [store parseLine:@"host.example:3128:user:pass:word"];
    expect(d && [d.user isEqual:@"user"] && [d.password isEqual:@"pass:word"], "user:pass with colon");
    expect([store parseLine:@"not-a-proxy"] == nil, "reject junk");
    expect([store parseLine:@"host:99999"] == nil, "reject bad port");
    NSArray<NSString *> *issues = nil;
    NSArray *rows = [store recordsFromPastedText:@"1.1.1.1:1080\nbad\n2.2.2.2:1080\n" issues:&issues];
    expect(rows.count == 2 && issues.count == 1, "paste list keeps valid rows");
    if (!fail) fprintf(stderr, "PASS proxy store parse\n");
    return fail;
}
