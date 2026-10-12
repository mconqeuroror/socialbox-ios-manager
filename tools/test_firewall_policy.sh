#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 \
  "$ROOT/network-extension/PacketTunnel/HTTPProxyEndpoint.swift" \
  "$ROOT/network-extension/PacketTunnel/FirewallPolicy.swift" \
  "$ROOT/network-extension/PacketTunnel/ProxyDNS.swift" \
  "$ROOT/tools/test_firewall_policy.swift" -o "$TEST_DIR/firewall-policy"
"$TEST_DIR/firewall-policy"
