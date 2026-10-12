#import <Foundation/Foundation.h>

// Device identity profile applied to a container at launch.
// Schema mirrors profiles/schema.json; keep both in sync.

typedef NS_ENUM(NSInteger, RBXIDFAPosture) {
    RBXIDFAPostureRandom = 0,
    RBXIDFAPostureZeroWithATTDenied = 1,
};

@interface RBXDeviceProfile : NSObject

@property (nonatomic, strong) NSString *containerId;
@property (nonatomic, strong) NSDictionary *rawProfile;

- (instancetype)initWithDictionary:(NSDictionary *)dict error:(NSError **)error;

// Resolved fields (nil if not present in profile)
- (id)mgAnswer:(NSString *)key;                    // any MobileGestalt plist override
- (NSDictionary<NSString *, id> *)overrides;
- (NSString *)valueForPath:(NSString *)dotPath;      // e.g. "device.productType"

- (NSString *)udid;
- (NSString *)serialNumber;
- (NSString *)wifiMac;
- (NSString *)btMac;
- (NSString *)imei1;
- (NSString *)productType;
- (NSString *)iosVersion;
- (NSString *)deviceName;
- (NSString *)idfa;
- (NSString *)idfv;
- (NSString *)redditInstallId;
- (NSString *)redditInstallTimestampMs;
- (NSString *)redditDeviceName;
- (NSString *)redditUserAgent;
- (NSString *)redditScreenWidth;
- (NSString *)redditScreenHeight;
- (NSString *)redditFontSize;
- (NSString *)redditExternalInstallationId;
- (NSString *)proxyURL;
- (NSString *)timezone;
- (NSString *)carrierName;
- (NSString *)mcc;
- (NSString *)mnc;
- (double)bootTimeOffsetSeconds;
- (RBXIDFAPosture)idfaPosture;
- (BOOL)isGeoConsistent;                             // set by daemon before launch

+ (NSString *)profilesDirectory;

@end
