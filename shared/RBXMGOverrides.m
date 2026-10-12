#import "RBXMGOverrides.h"

static id RBXValueAtPath(NSDictionary *profile, NSString *path) {
    id value = profile;
    for (NSString *part in [path componentsSeparatedByString:@"."]) {
        if (![value isKindOfClass:[NSDictionary class]]) return nil;
        value = ((NSDictionary *)value)[part];
    }
    if (value == [NSNull null]) return nil;
    return value;
}

NSDictionary<NSString *, id> *RBXBuildMGOverrides(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) return @{};

    static NSDictionary<NSString *, NSString *> *mapping;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mapping = @{
            @"UniqueDeviceID": @"serials.udid",
            @"UniqueDeviceIDData": @"serials.udidData",
            @"InverseDeviceID": @"serials.inverseDeviceId",
            @"SerialNumber": @"serials.serialNumber",
            @"MLBSerialNumber": @"serials.mlb",
            @"InternationalMobileEquipmentIdentity": @"serials.imei1",
            @"InternationalMobileEquipmentIdentity2": @"serials.imei2",
            @"MobileEquipmentIdentifier": @"serials.meid",
            @"IntegratedCircuitCardIdentifier": @"serials.iccid",
            @"IntegratedCircuitCardIdentifier2": @"serials.iccid2",
            @"WifiAddress": @"serials.wifiMac",
            @"WifiAddressData": @"serials.wifiMacData",
            @"BluetoothAddress": @"serials.btMac",
            @"BluetoothAddressData": @"serials.btMacData",
            @"EthernetMacAddress": @"serials.ethMac",
            @"IOPlatformSerialNumber": @"serials.serialNumber",
            @"IOPlatformUUID": @"serials.platformUUID",
            @"BasebandSerialNumber": @"serials.basebandSerial",
            @"BasebandUniqueId": @"serials.basebandUniqueId",
            @"ChipID": @"device.chipId",
            @"UniqueChipID": @"serials.uniqueChipId",
            @"HardwarePlatform": @"device.hwPlatform",
            @"ProductType": @"device.productType",
            @"HWModelStr": @"device.hwModelStr",
            @"MarketingProductName": @"device.marketingName",
            @"ModelNumber": @"device.modelNumber",
            @"RegulatoryModelNumber": @"device.regulatoryModel",
            @"ProductVersion": @"device.iosVersion",
            @"BuildVersion": @"device.buildVersion",
            @"DeviceClass": @"device.deviceClass",
            @"RegionCode": @"device.regionCode",
            @"DeviceName": @"device.deviceName",
            @"UserAssignedDeviceName": @"device.deviceName",
            @"GSDeviceName": @"device.deviceName",
            @"DeviceColor": @"device.color",
            @"MobileSubscriberCountryCode": @"device.carrier.mcc",
            @"MobileSubscriberNetworkCode": @"device.carrier.mnc",
            @"SIMStatus": @"device.simStatus",
            @"IDFA": @"ids.idfa",
            @"IDFV": @"ids.idfv",
        };
    });

    NSDictionary *explicit = [profile[@"mgOverrides"] isKindOfClass:[NSDictionary class]]
        ? profile[@"mgOverrides"] : nil;
    NSMutableDictionary *result = explicit ? [explicit mutableCopy]
                                           : [NSMutableDictionary dictionary];
    [mapping enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *path, BOOL *stop) {
        id value = RBXValueAtPath(profile, path);
        // Explicitly unavailable catalog fields must overwrite an older draft's
        // overrides and remain in the hook allowlist, never fall through to the
        // physical device. Keep legacy handling for other optional empty fields.
        if ([value isKindOfClass:NSString.class] && ![value length] &&
            ![@[@"InternationalMobileEquipmentIdentity", @"ModelNumber"] containsObject:key]) return;
        if (value) result[key] = value;
    }];
    // The catalog policy represents a physical iPhone, never a simulator.
    result[@"IsSimulator"] = @NO;
    return result;
}
