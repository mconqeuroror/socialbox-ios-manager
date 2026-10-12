#!/usr/bin/env python3
"""Generate the supervised per-app VPN payload and MDM app assignments."""

from __future__ import annotations

import argparse
import json
import plistlib
import uuid
from pathlib import Path


def fnv1a(value: str) -> int:
    result = 1469598103934665603
    for byte in value.encode():
        result ^= byte
        result = (result * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return result


def bundle_id(profile_id: str) -> str:
    return f"com.redditbox.profile.p{fnv1a(profile_id):016x}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profiles", nargs="+", help="profile IDs to manage")
    parser.add_argument("--output", default="build/redditbox-per-app-vpn.mobileconfig")
    parser.add_argument("--mapping-output", default="build/redditbox-mdm-app-mapping.json")
    args = parser.parse_args()

    vpn_uuid = str(uuid.uuid4()).upper()
    payload_uuid = str(uuid.uuid4()).upper()
    bundle_ids = [bundle_id(profile) for profile in args.profiles]
    vpn_payload = {
        "PayloadType": "com.apple.vpn.managed.applayer",
        "PayloadVersion": 1,
        "PayloadIdentifier": "com.redditbox.mdm.per-app-vpn",
        "PayloadUUID": payload_uuid,
        "PayloadDisplayName": "RedditBox Per-App VPN",
        "UserDefinedName": "RedditBox Per-App VPN",
        "VPNType": "VPN",
        "VPNSubType": "com.redditbox.firewall",
        "VPN": {
            "ProviderType": "app-proxy",
            "ProviderBundleIdentifier": "com.redditbox.firewall.PacketTunnel",
            "RemoteAddress": "RedditBox default-deny firewall",
            "OnDemandEnabled": 1,
            "OnDemandRules": [{"Action": "Connect"}],
        },
        "VPNUUID": vpn_uuid,
        "OnDemandMatchAppEnabled": 1,
        "SafariDomains": [
            "reddit.com",
            ".reddit.com",
            "redd.it",
            ".redd.it",
            "redditstatic.com",
            ".redditstatic.com",
        ],
        "VendorConfig": {
            "policyVersion": 2,
            "scope": "per-app",
            "outOfProcessAuthCovered": True,
            "managedBundleIdentifiers": bundle_ids + ["com.reddit.Reddit"],
        },
    }
    document = {
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": "com.redditbox.mdm",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadDisplayName": "RedditBox Managed Per-App VPN",
        "PayloadRemovalDisallowed": True,
        "PayloadContent": [vpn_payload],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(document, fmt=plistlib.FMT_XML))

    # Per-app association is an MDM app-management attribute, not a setting an
    # app or ldid can grant itself. Feed this manifest to the MDM install/manage
    # application operation after the clones are registered.
    mapping = {
        "vpnUUID": vpn_uuid,
        "assignments": [
            {
                "profileId": profile,
                "bundleIdentifier": identifier,
                "Attributes": {"VPNUUID": vpn_uuid},
            }
            for profile, identifier in zip(args.profiles, bundle_ids)
        ]
        + [
            {
                "profileId": "__original_reddit_deny_only__",
                "bundleIdentifier": "com.reddit.Reddit",
                "Attributes": {"VPNUUID": vpn_uuid},
            }
        ],
    }
    mapping_output = Path(args.mapping_output)
    mapping_output.parent.mkdir(parents=True, exist_ok=True)
    mapping_output.write_text(json.dumps(mapping, indent=2) + "\n")
    print(f"Wrote {output}")
    print(f"Wrote {mapping_output}")
    print("The device must be supervised and each clone must be marked managed by MDM.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
