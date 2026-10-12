#!/usr/bin/env python3
"""Check the experimental compiler/reader against hash-pinned Apple PF headers.

This is deliberately separate from normal builds: supply an already acquired
xnu-8796.141.3 header directory. No downloads, device access or kernel writes.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--headers", type=Path, required=True)
headers = parser.parse_args().headers.resolve()
root = Path(__file__).resolve().parents[1]
# Also checks the four upstream file hashes and all existing diagnostic fields.
subprocess.run([sys.executable, str(root / "tools/test_pf_readonly_abi.py"),
                "--headers", str(headers)], check=True)

sizes = {
    "RBXPFRuleImage": "pf_rule", "RBXPFRuleRequest": "pfioc_rule",
    "RBXPFStatusRequest": "pf_status", "RBXPFAnchorRequest": "pfioc_ruleset",
    "RBXPFPoolRequest": "pfioc_pooladdr", "RBXPFInterfaceImage": "pfi_kif",
    "RBXPFInterfaceRequest": "pfioc_iface", "RBXPFStatesRequest": "pfioc_states",
}
offsets = {
    "RBXPF_RULE_OFFSET": ("pfioc_rule", "rule"),
    "RBXPFRuleDestination": ("pf_rule", "dst.addr.v.a.addr"),
    "RBXPFRuleDestinationMask": ("pf_rule", "dst.addr.v.a.mask"),
    "RBXPFRuleDestinationPortLow": ("pf_rule", "dst.xport.range.port[0]"),
    "RBXPFRuleDestinationPortHigh": ("pf_rule", "dst.xport.range.port[1]"),
    "RBXPFRuleDestinationPortOp": ("pf_rule", "dst.xport.range.op"),
    "RBXPFRuleSkip": ("pf_rule", "skip"),
    "RBXPFRuleLabel": ("pf_rule", "label"),
    "RBXPFRulePoolFamily": ("pf_rule", "rpool.af"),
    "RBXPFRuleCounters": ("pf_rule", "evaluations"),
    "RBXPFRuleOwner": ("pf_rule", "owner"),
    "RBXPFRuleStates": ("pf_rule", "states"),
    "RBXPFRuleSourceNodes": ("pf_rule", "src_nodes"),
    "RBXPFRuleNumber": ("pf_rule", "nr"),
    "RBXPFRuleCreatorUID": ("pf_rule", "cuid"),
    "RBXPFRuleCreatorPID": ("pf_rule", "cpid"),
    "RBXPFRuleAction": ("pf_rule", "action"),
    "RBXPFRuleDirection": ("pf_rule", "direction"),
    "RBXPFRuleQuick": ("pf_rule", "quick"),
    "RBXPFRuleKeepState": ("pf_rule", "keep_state"),
    "RBXPFRuleFamily": ("pf_rule", "af"),
    "RBXPFRuleProtocol": ("pf_rule", "proto"),
    "RBXPFRuleTCPFlags": ("pf_rule", "flags"),
    "RBXPFRuleTCPFlagMask": ("pf_rule", "flagset"),
    "RBXPFRequestAction": ("pfioc_rule", "action"),
    "RBXPFRequestTicket": ("pfioc_rule", "ticket"),
    "RBXPFRequestNumber": ("pfioc_rule", "nr"),
    "RBXPFRequestAnchorCall": ("pfioc_rule", "anchor_call"),
    "RBXPFStatusRunning": ("pf_status", "running"),
    "RBXPFStatusStates": ("pf_status", "states"),
    "RBXPFStatusSourceNodes": ("pf_status", "src_nodes"),
    "RBXPFStatusChecksum": ("pf_status", "pf_chksum"),
    "RBXPFPoolTicket": ("pfioc_pooladdr", "ticket"),
    "RBXPFPoolCount": ("pfioc_pooladdr", "nr"),
    "RBXPFPoolRuleNumber": ("pfioc_pooladdr", "r_num"),
    "RBXPFPoolAction": ("pfioc_pooladdr", "r_action"),
    "RBXPFInterfaceFlags": ("pfi_kif", "pfik_flags"),
}
commands = {
    "RBXPF_GET_STATUS": "DIOCGETSTATUS", "RBXPF_GET_RULES": "DIOCGETRULES",
    "RBXPF_GET_RULE": "DIOCGETRULE", "RBXPF_GET_ANCHORS": "DIOCGETRULESETS",
    "RBXPF_GET_POOL": "DIOCGETADDRS", "RBXPF_GET_INTERFACES": "DIOCIGETIFACES",
    "RBXPF_GET_STATES": "DIOCGETSTATES",
}
constants = {
    "RBXPFPass": "PF_PASS", "RBXPFDrop": "PF_DROP", "RBXPFScrub": "PF_SCRUB",
    "RBXPFNat": "PF_NAT", "RBXPFBinat": "PF_BINAT", "RBXPFRdr": "PF_RDR",
    "RBXPFDummynet": "PF_DUMMYNET", "RBXPFOut": "PF_OUT", "RBXPFEqual": "PF_OP_EQ",
    "RBXPFKeepState": "PF_STATE_NORMAL", "RBXPFTcpSyn": "TH_SYN", "RBXPFTcpAck": "TH_ACK",
    "RBXPF_SKIP_FLAG": "PFI_IFLAG_SKIP", "RBXPFStateSize": "sizeof(struct pfsync_state)",
}
expressions = [f"sizeof({ours}) == sizeof(struct {apple})" for ours, apple in sizes.items()]
expressions += [f"{ours} == offsetof(struct {struct}, {field})" for ours, (struct, field) in offsets.items()]
expressions += [f"{ours} == {apple}" for ours, apple in {**commands, **constants}.items()]
for ours, apple, fields in (
    ("RBXPFInterfaceRequest", "pfioc_iface", {"name": "pfiio_name", "buffer": "pfiio_buffer",
        "elementSize": "pfiio_esize", "count": "pfiio_size", "nzero": "pfiio_nzero", "flags": "pfiio_flags"}),
    ("RBXPFStatesRequest", "pfioc_states", {"length": "ps_len", "buffer": "ps_u"}),
):
    expressions += [f"offsetof({ours}, {a}) == offsetof(struct {apple}, {b})" for a, b in fields.items()]
expressions += [
    "sizeof(((struct pf_rule *)0)->skip) == 64",
    "offsetof(struct pf_rule,ticket) - offsetof(struct pf_rule,evaluations) == 40",
    "sizeof(((struct pf_rule *)0)->states) == 4",
    "sizeof(((struct pf_rule *)0)->src_nodes) == 4",
    "sizeof(((struct pf_rule *)0)->label) == 64",
    "sizeof(((struct pf_rule *)0)->owner) == 64",
    "sizeof(((struct pf_status *)0)->pf_chksum) == 16",
    "sizeof(((struct pfi_kif *)0)->pfik_name) == 16",
    "PF_GET_NONE == 0", "PF_ADDR_ADDRMASK == 0", "PF_NOPFROUTE == 0", "PF_RULESET_MAX == 6",
]
lines = ['#define PRIVATE 1', '#include "pfvar.h"', '#include <netinet/tcp.h>',
         '#include "RBXPFKernelABI.h"']
lines += [f'_Static_assert({expression}, "ABI check {i}");' for i, expression in enumerate(expressions)]
with tempfile.TemporaryDirectory(prefix="socialbox-pf-kernel-abi-") as temp:
    source = Path(temp) / "abi.c"
    source.write_text("\n".join(lines) + "\n")
    for sdk, target in (([], []), (["--sdk", "iphoneos"], ["-target", "arm64-apple-ios15.0"]),
                        (["--sdk", "iphoneos"], ["-target", "arm64e-apple-ios15.0"])):
        subprocess.run(["xcrun", *sdk, "clang", *target, "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-I", str(headers), "-I", str(root / "experimental/pf"),
                        "-fsyntax-only", str(source)], check=True)
print(f"PASS: {len(expressions)} compiler/readback ABI assertions on host, arm64 and arm64e")
