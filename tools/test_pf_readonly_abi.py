#!/usr/bin/env python3
"""Validate diagnostic ABI constants against pinned, separately acquired Apple headers.

Use --headers DIR containing pfvar.h, libkern/tree.h, net/radix.h and route.h
from apple-oss-distributions/xnu tag xnu-8796.141.3. No downloads or device access.
This validates host and arm64-iOS compiler layout, not runtime enforcement.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--headers", type=Path, required=True)
headers = parser.parse_args().headers.resolve()
expected = {
    "pfvar.h": "c653221b8ec079028367584944ae4e09dde15f37bec72bdc0476ad2a1f57984a",
    "route.h": "dcd77dcb77e8468004b3fe667ec490a8bf0849487c2b832dcee8010ffbdea92d",
    "libkern/tree.h": "7bde9f6ba98f15e326813b82dc0e5e9e2d3013c025a91c946f9cd238e80e4939",
    "net/radix.h": "6bd5fd9877eb42f21143260d5caa4b169b02e0e50378703506a86191a3f126f4",
}
for name, digest in expected.items():
    assert hashlib.sha256((headers / name).read_bytes()).hexdigest() == digest, f"Wrong Apple header revision: {name}"

sizes = {"pf_status": 440, "pf_rule": 1040, "pfioc_rule": 3104, "pfioc_ruleset": 1092,
         "pfioc_states": 16, "pfsync_state": 297, "pf_rule_addr": 64, "pf_addr_wrap": 48,
         "rt_msghdr": 92, "rt_msghdr2": 92}
fields = {
 "pf_status": {"running": 376, "states": 380, "src_nodes": 384, "pf_chksum": 424},
 "pfioc_rule": {"action": 0, "ticket": 4, "pool_ticket": 8, "nr": 12, "anchor": 16, "anchor_call": 1040, "rule": 2064},
 "pfioc_ruleset": {"nr": 0, "path": 4, "name": 1028},
 "pfioc_states": {"ps_len": 0, "ps_u": 8},
 "pf_rule": {"src": 0, "dst": 64, "label": 192, "ifname": 256, "qname": 272, "pqname": 336,
             "tagname": 400, "match_tagname": 464, "overload_tblname": 528, "entries": 560,
             "rpool": 576, "evaluations": 648, "packets": 656, "bytes": 672, "owner": 696,
             "priority": 760, "kif": 768, "anchor": 776, "overload_tbl": 784, "states": 904,
             "uid": 976, "gid": 988, "rule_flag": 1000, "action": 1004, "direction": 1005,
             "log": 1006, "logif": 1007, "quick": 1008, "ifnot": 1009, "match_tag_not": 1010,
             "natpass": 1011, "keep_state": 1012, "af": 1013, "proto": 1014, "type": 1015,
             "code": 1016, "flags": 1017, "flagset": 1018, "min_ttl": 1019, "allow_opts": 1020,
             "rt": 1021, "return_ttl": 1022, "tos": 1023, "anchor_relative": 1024,
             "anchor_wildcard": 1025, "flush": 1026, "proto_variant": 1027, "extfilter": 1028,
             "extmap": 1029, "dnpipe": 1032, "dntype": 1036},
 "pf_rule_addr": {"addr": 0, "xport": 48, "neg": 56},
 "pf_addr_wrap": {"type": 40, "iflags": 41},
 "pfsync_state": {"id": 0, "ifname": 8, "lan": 24, "gwy": 48, "ext_lan": 72, "ext_gwy": 96,
                  "unlink_hooks": 200, "rule": 216, "anchor": 220, "nat_rule": 224, "creation": 228,
                  "expire": 236, "packets": 244, "bytes": 260, "af_lan": 282, "af_gwy": 283,
                  "proto": 284, "direction": 285, "timeout": 288},
 "rt_msghdr": {"rtm_msglen": 0, "rtm_version": 2, "rtm_index": 4, "rtm_flags": 8, "rtm_addrs": 12},
}
commands = {"DIOCGETSTATUS": 0xc1b84415, "DIOCGETRULES": 0xcc204406, "DIOCGETRULE": 0xcc204407,
            "DIOCGETRULESETS": 0xc444443a, "DIOCGETRULESET": 0xc444443b, "DIOCGETSTATES": 0xc0104419}
lines = ['#define PRIVATE 1', '#include <stddef.h>', '#include <sys/ioctl.h>', '#include "pfvar.h"', '#undef PRIVATE', '#include "route.h"']
for struct, size in sizes.items():
    lines.append(f'_Static_assert(sizeof(struct {struct})=={size}, "{struct} size");')
for struct, members in fields.items():
    for member, offset in members.items():
        lines.append(f'_Static_assert(offsetof(struct {struct},{member})=={offset}, "{struct}.{member}");')
for name, value in commands.items():
    lines.append(f'_Static_assert({name}=={value}UL, "{name}");')
lines.append('int main(void) { return 0; }')
with tempfile.TemporaryDirectory(prefix="socialbox-pf-abi-") as temp:
    source = Path(temp) / "abi.c"
    source.write_text("\n".join(lines) + "\n")
    for target in ([], ["--sdk", "iphoneos"]):
        command = ["xcrun", *target, "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(headers)]
        if target:
            command += ["-target", "arm64-apple-ios15.0"]
        subprocess.run(command + ["-fsyntax-only", str(source)], check=True)
count = len(sizes) + sum(len(f) for f in fields.values()) + len(commands)
print(f"PASS: {count} pinned Apple ABI size/offset/ioctl assertions on host and arm64-iOS compilers")
