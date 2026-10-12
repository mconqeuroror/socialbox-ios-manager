#import <Foundation/Foundation.h>
#import "RBXAcceptanceChecks.h"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        id state = [NSPropertyListSerialization propertyListWithData:input options:NSPropertyListImmutable format:nil error:nil];
        if (!state) state = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        if (![state isKindOfClass:NSDictionary.class]) { fprintf(stderr, "Expected launcher state dictionary.\n"); return 2; }
        double now = argc == 2 ? atof(argv[1]) : NSDate.date.timeIntervalSince1970;
        NSData *output = [NSJSONSerialization dataWithJSONObject:RBXAcceptanceChecks(state, now) options:NSJSONWritingPrettyPrinted error:nil];
        [NSFileHandle.fileHandleWithStandardOutput writeData:output];
    }
}
