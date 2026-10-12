#import <CoreLocation/CoreLocation.h>
#import "../lucid/Manager/SBLocationStore.m"

static int fail = 0;
static void expect(int ok, const char *msg) {
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", msg);
        fail = 1;
    }
}

int main(void) {
    CLLocationCoordinate2D c;
    expect([SBLocationStore parseText:@"48.1486, 17.1077" intoCoordinate:&c] &&
               fabs(c.latitude - 48.1486) < 0.0001 && fabs(c.longitude - 17.1077) < 0.0001,
           "comma pair");
    expect([SBLocationStore parseText:@"-33.8688 151.2093" intoCoordinate:&c] && c.latitude < 0, "space pair");
    expect(![SBLocationStore parseText:@"Bratislava" intoCoordinate:&c], "reject place name");
    expect(![SBLocationStore parseText:@"91.0, 10.0" intoCoordinate:&c], "reject bad lat");
    if (!fail) fprintf(stderr, "PASS location store parse\n");
    return fail;
}
