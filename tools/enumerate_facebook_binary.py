#!/usr/bin/env python3
"""Produce a bounded, public-name-only Facebook supplement from a private IPA.

Run enumerate_leak_binary.py first with --details-output in private storage.
This tool verifies that full inventory's IPA/scanner hashes, then preserves
selected structural references, narrow name literals, original declarations and
exact slice-relative offsets. It never reads device storage or observes traffic.
No extracted executable, certificate, signature bytes, URL paths/queries or
account values are written. Selection counts and caps make omissions explicit.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import zipfile

from enumerate_leak_binary import InvalidBinary, MachO, checked, macho_slices, sha, strings


TOPICS = {
    "platform_identifiers": r"identifierForVendor|advertisingIdentifier|ASIdentifierManager|ATTrackingManager|trackingAuthorizationStatus",
    "family_device_identity": r"FamilyDeviceID|familyDeviceID|familyDeviceId|family_device_id|appScopedDeviceID|app_scoped_device_id|FBAnalyticsGetDeviceID|FBBlockAndFetchDeviceIDFromKeychain|FBDeviceIdentifiersReliabilityLogger|storeIdentifierValues:|storedDeviceID|FBMachineID|machineID|MachineID",
    "keychain": r"^_SecItem|FBKeychain|FBBaseKeychain|FBAuthenticationKeychain|_keychainAccessGroup|_readStringFromKeychain:|_writeString:toKeychain:|sessionKeychainWithAppBundle:|shouldFetchFromSharedKeychain|shouldFetchFromFBAccessOnlyKeychain",
    "preferences_groups_cloud": r"NSUserDefaults|CFPreferences|standardUserDefaults|initWithSuiteName:|containerURLForSecurityApplicationGroupIdentifier:|NSUbiquitousKeyValueStore|CKContainer|NSFileManager|NSHomeDirectory",
    "app_integrity": r"AppAttest|AppIntegrity|appIntegrity|appintegrity|DeviceCheck|attestKey:|generateKeyWithCompletionHandler:|generateAssertion:|generateTokenWithCompletionHandler:|DCDevice|ZeroCodeAttestation",
    "mqtt": r"MQTT|Mqtt|mqtt",
    "meta_transport": r"Tigon|tigon|proxygen|Proxygen|Liger|liger|Fizz|fizz|QUIC|quic|HTTP3|http3",
    "socket_transport": r"^_(?:socket|connect|connectx|send|sendto|sendmsg|recv|recvfrom|recvmsg|getaddrinfo|getnameinfo|CFStream[A-Za-z_]+|CFSocket[A-Za-z_]+|nw_[A-Za-z_]+)$",
    "background_push_voip": r"PKPushRegistry|PKPushCredentials|CXProvider|CXCallController|BGTaskScheduler|BGProcessingTask|backgroundSessionConfiguration|registerForRemoteNotifications|didReceiveRemoteNotification|pushRegistry:|setKeepAliveTimeout:|beginBackgroundTask",
    "user_agent": r"(?:[Uu]serAgent|[Uu]ser_agent)",
    "web_auth_cookie": r"WKWebView|WKWebsiteDataStore|WKHTTPCookieStore|ASWebAuthenticationSession|SFAuthenticationSession|SFSafariViewController|HTTPCookieStorage|UIPasteboard",
    "meta_sdk_candidates": r"^(?:_OBJC_CLASS_\$_)?(?:FBSDK|FBAd[A-Z]|FBAnalytics|FBMobileConfig|FBAppEvents|RCT|Odin|FBFamilyDevice|FBAppAttestation|FBTigon|FBMQTT)|MetaEncryptedMessaging|facebook.*(?:tigon|msys)|SPTAppRemote|Widevine",
}
COMPILED = {k: re.compile(v) for k, v in TOPICS.items()}
LITERAL = re.compile(r"(?:^(?:X-FB-|x-fb-|X-IG-|x-ig-|FBAN|FBAV|FBBV|FBDM|FBLC|FBCR|FBMF|FBBD|FBDV|FBSV|FBSN)|(?:family.?device|app.?scoped.?device|machine.?id|analytics.device_id|device_id|install.?id|installation|app.?attest|appintegrity|devicecheck|platformFamily|CROSS_APP_DEVICE_KEY|LEGACY_DEVICE_KEY|shared_device_key|legacy_device_key|^mid$|^datr$))", re.I)
SAFE_LITERAL = re.compile(r"^[A-Za-z][A-Za-z0-9_.:/-]{1,199}$")
RECORD_KINDS = ("selector_references", "class_references", "class_definitions", "undefined_symbols")
COUNTS = (*RECORD_KINDS, "method_name_strings", "swift_type_descriptors")
MAX_EXAMPLES_PER_IMAGE_KIND = 32
INFO_FIELDS = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers", "FBKeychainAccessGroup", "NSExtension", "NSAppTransportSecurity")


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def signature_declarations(data, macho):
    """Bounds-check an embedded SuperBlob; do not validate code signing trust."""
    result = []
    for command in macho.commands:
        if command["command"] != "0x1d":
            continue
        if command["size"] < 16:
            raise InvalidBinary("short LC_CODE_SIGNATURE")
        offset, size = struct.unpack_from("<II", checked(data, int(command["offset"], 16) + 8, 8))
        blob = bytes(checked(data, offset, size))
        magic, length, count = struct.unpack_from(">III", checked(blob, 0, 12))
        if magic != 0xfade0cc0 or length > size or length < 12 or count > (length - 12) // 8:
            raise InvalidBinary("invalid embedded signature SuperBlob")
        for index in range(count):
            slot, child = struct.unpack_from(">II", blob, 12 + index * 8)
            child_magic, child_length = struct.unpack_from(">II", checked(blob[:length], child, 8))
            raw = bytes(checked(blob[:length], child, child_length))
            if child_length < 8:
                raise InvalidBinary("short signature child")
            if child_magic in (0xfade7171, 0xfade7172):
                entry = {"slot": slot, "magic": hex(child_magic), "offset": hex(offset + child), "size": child_length, "sha256": sha(raw)}
                if child_magic == 0xfade7171:
                    entry["xml_entitlements"] = plistlib.loads(raw[8:])
                    entry["meaning"] = "Original embedded XML declaration only; not trust validation, clone entitlements, or runtime permission proof."
                else:
                    entry["meaning"] = "DER entitlement blob identity only; DER contents not decoded or compared to XML."
                result.append(entry)
    return result


def build(ipa, details):
    with gzip.open(details, "rt") as stream:
        source = json.load(stream)
    scanner = Path(__file__).with_name("enumerate_leak_binary.py")
    ipa_hash = file_hash(ipa)
    if source["ipa_sha256"] != ipa_hash or source["scanner_sha256"] != file_hash(scanner):
        raise ValueError("private source inventory IPA/scanner mismatch; rerun scanner")
    if source["errors"] or any(any(s["unresolved_references"].values()) for f in source["mach_o_files"] for s in f["slices"]):
        raise ValueError("resolve structural scanner errors/references first")
    main_bundles = [b for b in source["bundles"] if b["path"].endswith(".app/Info.plist")]
    if len(main_bundles) != 1 or main_bundles[0].get("CFBundleIdentifier") != "com.facebook.Facebook" or main_bundles[0].get("CFBundleExecutable") != "Facebook":
        raise ValueError("supplement requires the original Facebook app identity")
    result = {
        "schemaVersion": 1,
        "appType": "facebook",
        "ipa_sha256": ipa_hash,
        "ipa_size": Path(ipa).stat().st_size,
        "scanner": "tools/enumerate_leak_binary.py",
        "scanner_sha256": file_hash(scanner),
        "supplement_scanner": "tools/enumerate_facebook_binary.py",
        "supplement_scanner_sha256": file_hash(__file__),
        "private_full_details_gzip_sha256": file_hash(details),
        "zip_entry_count": source["zip_entry_count"],
        "selection": {"patterns": TOPICS, "literal_pattern": LITERAL.pattern, "literal_charset": SAFE_LITERAL.pattern, "max_examples_per_image_kind": MAX_EXAMPLES_PER_IMAGE_KIND},
        "semantics": [
            "All offsets are hexadecimal and relative to the identified Mach-O slice, including references and original signature blobs.",
            "Structural references and definitions establish static presence, not invocation, caller attribution, SDK ownership or storage-to-wire flow.",
            "Short literals are candidates only; no persisted keys/values or emitted headers were observed. URL hosts omit paths and queries.",
            "Topic examples are capped per image and record kind; match_count includes omitted matches. Raw structural tables remain in the hash-bound private full inventory.",
            "Original XML declarations are not effective clone permissions. DER entitlements are hashed but not decoded. No signature trust validation is performed.",
            "No first-run storage, two-clone, proxy egress, attestation, background wake or device compatibility acceptance is established.",
            "Missing static names do not establish absence: dynamic lookup, web content, downloaded code/data and remote configuration remain unresolved.",
        ],
        "framework_directories": source["framework_directories"],
        "privacy_manifests": source["privacy_manifests"],
        "bundles": [],
        "mach_o_files": [],
        "topics": {k: [] for k in TOPICS},
        "errors": [],
    }
    with zipfile.ZipFile(ipa) as archive:
        if len(set(archive.namelist())) != len(archive.namelist()):
            raise ValueError("duplicate archive names")
        for bundle in source["bundles"]:
            if bundle["path"].endswith((".app/Info.plist", ".appex/Info.plist")):
                raw = archive.read(bundle["path"])
                value = plistlib.loads(raw)
                result["bundles"].append({"path": bundle["path"], "sha256": sha(raw), "declarations": {k: value[k] for k in INFO_FIELDS if k in value}})
        for binary in source["mach_o_files"]:
            raw = archive.read(binary["path"])
            if sha(raw) != binary["sha256"]:
                raise ValueError("source Mach-O identity mismatch")
            image = {k: binary[k] for k in ("path", "sha256", "size")}
            image["slices"] = []
            parts = macho_slices(raw)
            if len(parts) != len(binary["slices"]):
                raise ValueError("slice count mismatch")
            for (offset, data), part in zip(parts, binary["slices"]):
                if sha(data) != part["sha256"] or hex(offset) != part["file_offset"]:
                    raise ValueError("slice identity mismatch")
                macho = MachO(data)
                selected = {k: part[k] for k in ("file_offset", "sha256", "cpu_type", "cpu_subtype", "encryption", "unresolved_references")}
                selected["counts"] = {k: len(part[k]) for k in COUNTS}
                selected["linked_frameworks"] = part["dylibs"]
                selected["signature_declarations"] = signature_declarations(data, macho)
                selected["literal_candidates"] = []
                for section in macho.sections:
                    if section["name"] not in ("__cstring", "__swift5_reflstr") or section["zerofill"]:
                        continue
                    for at, name in strings(data, section):
                        if SAFE_LITERAL.fullmatch(name) and LITERAL.search(name):
                            selected["literal_candidates"].append({"name": name, "offset": hex(at), "section": section["name"]})
                selected["url_host_literals"] = part["url_host_literals"]
                for topic, pattern in COMPILED.items():
                    for kind in RECORD_KINDS:
                        hits = [r for r in part[kind] if pattern.search(r["name"])]
                        if hits:
                            result["topics"][topic].append({"path": binary["path"], "slice_sha256": part["sha256"], "kind": kind, "match_count": len(hits), "examples": hits[:MAX_EXAMPLES_PER_IMAGE_KIND]})
                image["slices"].append(selected)
            result["mach_o_files"].append(image)
    result["totals"] = {k: sum(s["counts"][k] for f in result["mach_o_files"] for s in f["slices"]) for k in COUNTS}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--details", required=True, help="private full JSON.gz from enumerate_leak_binary.py")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = build(args.ipa, args.details)
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"ipa_sha256": result["ipa_sha256"], "mach_o_files": len(result["mach_o_files"]), "totals": result["totals"], "errors": result["errors"]}))


if __name__ == "__main__":
    main()
