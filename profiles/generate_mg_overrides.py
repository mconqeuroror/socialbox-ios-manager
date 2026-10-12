#!/usr/bin/env python3
"""Generate the mgOverrides map for a container profile.

The daemon does this on-device at profile-apply time; this host-side script is the
reference implementation + test harness for the mapping (profile sections -> flat
MobileGestalt key/value map), so both sides stay in sync.

Usage: generate_mg_overrides.py <profile.json> [out.json]
"""
import json
import sys

# MG key <- profile path. Keep in sync with PLAN.md §5.1 tables and
# daemon/RBXProfileGenerator.m. Capability keys are intentionally absent.
MG_MAP = {
    # device identity
    "UniqueDeviceID": "serials.udid",
    "UniqueDeviceIDData": "serials.udidData",
    "InverseDeviceID": "serials.inverseDeviceId",
    "SerialNumber": "serials.serialNumber",
    "MLBSerialNumber": "serials.mlb",
    "InternationalMobileEquipmentIdentity": "serials.imei1",
    "InternationalMobileEquipmentIdentity2": "serials.imei2",
    "MobileEquipmentIdentifier": "serials.meid",
    "IntegratedCircuitCardIdentifier": "serials.iccid",
    "IntegratedCircuitCardIdentifier2": "serials.iccid2",
    "WifiAddress": "serials.wifiMac",
    "WifiAddressData": "serials.wifiMacData",
    "BluetoothAddress": "serials.btMac",
    "BluetoothAddressData": "serials.btMacData",
    "EthernetMacAddress": "serials.ethMac",
    "IOPlatformSerialNumber": "serials.serialNumber",
    "IOPlatformUUID": "serials.platformUUID",
    "BasebandSerialNumber": "serials.basebandSerial",
    "BasebandUniqueId": "serials.basebandUniqueId",
    # SoC / board
    "ChipID": "device.chipId",
    "UniqueChipID": "serials.uniqueChipId",
    "HardwarePlatform": "device.hwPlatform",
    # marketing identity
    "ProductType": "device.productType",
    "HWModelStr": "device.hwModelStr",
    "MarketingProductName": "device.marketingName",
    "ModelNumber": "device.modelNumber",
    "RegulatoryModelNumber": "device.regulatoryModel",
    "ProductVersion": "device.iosVersion",
    "BuildVersion": "device.buildVersion",
    "DeviceClass": "device.deviceClass",
    "RegionCode": "device.regionCode",
    "DeviceName": "device.deviceName",
    "UserAssignedDeviceName": "device.deviceName",
    "GSDeviceName": "device.deviceName",
    "DeviceColor": "device.color",
    # cellular
    "MobileSubscriberCountryCode": "device.carrier.mcc",
    "MobileSubscriberNetworkCode": "device.carrier.mnc",
    "SIMStatus": "device.simStatus",
    # apple platform ids (not real MG keys; reserved for the hook layer)
    "IDFA": "ids.idfa",
    "IDFV": "ids.idfv",
}


def build_overrides(profile: dict) -> dict:
    out = {}
    for mg_key, path in MG_MAP.items():
        cur = profile
        for part in path.split("."):
            if not isinstance(cur, dict):
                cur = None
                break
            cur = cur.get(part)
        if isinstance(cur, str) and cur:
            out[mg_key] = cur
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    with open(sys.argv[1]) as f:
        profile = json.load(f)
    profile["mgOverrides"] = build_overrides(profile)
    out_path = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
    with open(out_path, "w") as f:
        json.dump(profile, f, indent=2)
    print(f"mgOverrides: {len(profile['mgOverrides'])} keys written to {out_path}")


if __name__ == "__main__":
    main()
