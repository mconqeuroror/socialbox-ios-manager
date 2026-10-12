#import <Foundation/Foundation.h>
#import <os/log.h>

static inline os_log_t rbxLogImpl(void) {
    static os_log_t sLog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLog = os_log_create("com.redditbox", "tweak");
    });
    return sLog;
}

#define RBXLog(fmt, ...) os_log_info(rbxLogImpl(), fmt, ##__VA_ARGS__)
#define RBXLogErr(fmt, ...) os_log_error(rbxLogImpl(), fmt, ##__VA_ARGS__)
#define RBXLogDebug(fmt, ...) os_log_debug(rbxLogImpl(), fmt, ##__VA_ARGS__)
