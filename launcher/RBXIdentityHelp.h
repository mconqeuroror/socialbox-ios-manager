#pragma once
#import <Foundation/Foundation.h>

// UI-003: explanations describe the existing hooks; none assert complete emulation.
static inline NSString *RBXIdentityFieldHelp(NSString *key) {
    NSDictionary *help = @{
        @"mlb": @"Synthetic logic-board serial used by supported identity queries. It has four hexadecimal characters followed by one decimal digit; it is not an Apple hardware record.",
        @"uniqueChipId": @"Synthetic chip identifier, as a positive unsigned 64-bit decimal number. Automatic fill prepares it and Save preserves that exact value.",
        @"bootTimeOffsetSeconds": @"Initial synthetic uptime in seconds (0–1209600). The absolute boot time below is the primary value; this field remains a compatibility fallback.",
        @"syntheticBootEpoch": @"Synthetic boot timestamp as Unix seconds, not a reboot of your phone. The runtime derives elapsed uptime from this stable time.",
        @"installTimestampMs": @"Synthetic Reddit installation timestamp as Unix milliseconds. It stays stable once saved; this does not change App Store installation history.",
        @"latitude": @"Synthetic latitude near the selected catalog city. Selecting a city fills both coordinates and its timezone. These are suggested coordinates, not GPS measurements from the proxy.",
        @"longitude": @"Synthetic longitude near the selected catalog city. Both coordinates are checked together before Save; changing them does not move the network exit.",
        @"automaticFill": @"Fill automatically prepares the entire supported identity: all device and app IDs, model, iOS/build, linked hardware/display values, carrier, locale, timezone, city/coordinates, installation/boot times, IDFA posture, font size and battery offset. Region is verified through the assigned or selected proxy. If proxy verification fails, the current draft is kept. Compatibility-policy switches are preserved. Nothing is saved automatically; review every field, run Check consistency, then Save.",
        @"productType": @"The model reported by this container. Choosing a model manually prepares matching draft identifiers while keeping a compatible selected iOS; Fill automatically chooses both model and iOS. Changes are available before first use; a locked identity requires a new container. This does not change your real iPhone, its speed, or the iOS required by the imported app.",
        @"iosVersion": @"The iOS version reported by supported identity hooks. The picker lists the versions in the installed catalog for the selected model, newest first. A single entry means that catalog has only one version for this model. This does not install iOS or add missing system features.",
        @"country": @"Two-letter country code. Set from proxy detects it automatically. An assigned container must keep its cloud proxy country; an unassigned container can request another supported region. This does not move the proxy.",
        @"locale": @"Language and regional formatting reported to the app, such as en_US for US English. Use the region button to fill a matching value.",
        @"carrierCode": @"MCC identifies the mobile country and MNC identifies the carrier. Auto fill suggests a catalog carrier for the proxy country. An IP network owner is not proof of a SIM carrier. You can choose another; this does not change your SIM or mobile plan.",
        @"city": @"City used for the container’s synthetic location. Choose a catalog city in the proxy country; this does not change the proxy’s actual location.",
        @"deviceName": @"A friendly device name reported by this profile. It does not rename the physical iPhone in Settings.",
        @"idfaPosture": @"Advertising identifier policy. Zero + ATT denied shows an all-zero IDFA read-only and reports denied tracking permission. Random makes the IDFA editable; enter or generate a non-zero value, then Check consistency before saving.",
        @"fontSize": @"Font-size preference sent in supported Reddit requests. The app controls how it renders text; this setting does not change the phone’s system text size.",
        @"batteryOffsetPercent": @"Offsets the container’s synthetic battery level by -8 to +8 percentage points. Zero keeps the synthetic cycle unchanged; it does not report or affect real battery charge.",
        @"serialNumber": @"Synthetic 10-character device serial for this container. It is not an Apple-issued serial or a warranty record.",
        @"udid": @"Synthetic device identifier: 8 hexadecimal characters, a dash, then 16 hexadecimal characters. New model templates use a generic random prefix, not a verified Apple hardware prefix.",
        @"imei1": @"Cellular equipment identifier. New model templates leave this empty because no verified model-specific IMEI prefix is provided. It does not change your modem or SIM.",
        @"wifiMac": @"Synthetic Wi-Fi interface address in the profile. It does not change the address your real phone uses to connect to a router.",
        @"btMac": @"Synthetic Bluetooth interface address in the profile. Keep it different from Wi-Fi MAC; this does not reprogram the Bluetooth radio.",
        @"platformUUID": @"UUID-shaped platform identifier generated for this container. Automatic fill creates a new visible draft value. You can review or replace it manually before Check and Save.",
        @"idfa": @"Advertising ID in UUID format. Under Zero + ATT denied it must be all zeros. Otherwise use the generated value.",
        @"idfv": @"Vendor identifier in UUID format, kept stable for this container. This is a different identifier from IDFA.",
        @"installId": @"Identifier for this Reddit installation. It stays stable after first use so an existing profile does not unexpectedly change identity.",
        @"externalInstallationId": @"A separate Reddit installation identifier used by supported request hooks. Keep the generated value unless you are testing a specific format.",
        @"appAttest": @"Allows supported Apple App Attest calls to reach the real service. This can help compatibility but may expose device-backed attestation. It is blocked by default.",
        @"deviceCheck": @"Allows supported Apple DeviceCheck calls to reach the real service. Device-backed signals can link activity outside this profile. It is blocked by default.",
        @"localNetworking": @"Allows loopback connections to services on this phone. This does not enable nearby-device or LAN access, and it does not replace the managed VPN requirement.",
        @"sensorAccess": @"Allows supported motion-sensor readings, such as accelerometer data. Real sensor values can be shared across profiles; blocking them may affect features.",
        @"networkMetadata": @"Allows supported APIs to reveal real network details. Keep off unless a feature needs them; it does not select or test a proxy.",
        @"thirdPartyNetwork": @"Allows SDK network paths otherwise blocked by the compatibility policy. This may enable analytics or login features. It does not remove the VPN or firewall checks.",
        @"strictTiming": @"Uses synthetic timing values in supported hooks. Turning it off may expose shared uptime or timing; turning it on can affect app compatibility.",
        @"systemClipboard": @"Allows the shared iOS clipboard, for example to paste a login code. Other profiles use that same clipboard. Off blocks supported clipboard access; RedditBox does not clear it.",
        @"timezone": @"Time zone reported to the app, such as America/New_York. It must belong to the chosen country.",
    };
    return help[key];
}
