#!/usr/bin/env python3
"""Actual diagnostic C with inert ioctl provider: no /dev/pf or device access."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def check(condition, description):
    global checks
    assert condition, description
    checks += 1

with tempfile.TemporaryDirectory(prefix="socialbox-pf-readonly-") as temp:
    executable = Path(temp) / "test"
    subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-g", str(ROOT / "tools/test_pf_readonly_inventory.c"),
                    "-o", str(executable)], check=True)

    def run(mode, code=0):
        result = subprocess.run([str(executable), mode], capture_output=True, text=True)
        check(result.returncode == code, f"{mode}: exit {result.returncode}, {result.stderr}")
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        check(not result.stderr, f"{mode}: sanitizers quiet")
        return rows

    rows = run("normal")
    summary = rows[-1]
    check(summary["enumerationComplete"], "complete deterministic fixture")
    check(not summary["enforcementVerified"], "inspection never proves enforcement")
    check((summary["anchors"], summary["rules"], summary["states"]) == (3, 1, 2), "enumeration counts")
    check(not rows[0]["atomicSnapshot"], "non-atomic snapshot explicit")
    check(not rows[0]["semanticExpansionComplete"], "tables and pools not silently complete")
    check({r["familyAction"] for r in rows if r["record"] == "ruleset"} == {0, 2, 4, 6, 8, 11}, "all six rulesets")
    check([r["path"] for r in rows if r["record"] == "anchor"] == ["", "safe", "safe/nested"], "recursive anchors")
    rule = next(r for r in rows if r["record"] == "rule")
    check(rule["source"]["address"] == "192.0.2.0", "IPv4 rule decode")
    check(rule["source"]["maskOrRangeEnd"] == "255.255.255.0", "mask decode")
    check(rule["source"]["portLow"] == 443 and rule["source"]["portHigh"] == 8443, "network-order rule ports")
    check(rule["destination"]["name"] == "allowed_destinations", "table name only")
    check(rule["uid"] == {"low": 501, "high": 502, "operator": 4}, "UID policy decode")
    check(rule["gid"] == {"low": 20, "high": 21, "operator": 4}, "GID policy decode")
    check(rule["evaluations"] == 0x100000003 and rule["bytes"] == [789, 1011], "64-bit counters")
    check(rule["label"] == 'quote"line\n', "JSON escaping")
    check(rule["anchorCall"] == "safe/nested" and rule["action"] == 1 and rule["quick"] == 1, "rule action and anchor")
    states = [r for r in rows if r["record"] == "state"]
    check(states[0]["lan"]["address"] == "192.0.2.8", "IPv4 state")
    check(states[1]["lan"]["address"] == "2001:db8::42", "IPv6 state")
    check(states[1]["externalGateway"]["portOrId"] == 446, "state ports")
    check(states[0]["packets"] == [0x200000003, 0x400000005], "host-order split counters")
    check(states[0]["bytes"] == [0x600000007, 0x800000009], "byte counters")
    check(states[0]["ageSeconds"] == 0x100000007 and states[0]["expiresInSeconds"] == 500, "packed unaligned 64-bit fields")
    check(states[0]["natRule"] == 0xffffffff, "no-NAT rule sentinel")
    check("adadadadadadadad" not in json.dumps(rows), "kernel pointers never serialized")
    empty = run("empty")[-1]
    check(empty["enumerationComplete"] and (empty["anchors"], empty["rules"], empty["states"]) == (1, 0, 0), "empty PF is valid, not enforcement")
    blocked = run("whitelist")
    check(len(blocked) == 9 and all(r["record"] == "error" for r in blocked), "mutations/reset/null/budgets rejected before ioctl")
    for scenario in ["permission", "status-invalid", "checksum-race", "rules-bound", "ticket-race", "rule-busy",
                     "rule-type", "rule-af", "rule-string", "anchor-bound", "anchor-depth", "anchor-slash",
                     "anchor-dot", "anchor-string", "anchor-race", "state-size-negative", "state-size-misaligned",
                     "state-size-bound", "state-return-negative", "state-return-large", "state-return-misaligned",
                     "state-truncated", "state-race", "state-af", "state-string"]:
        result = run(scenario, 2)
        check(result[-1]["enumerationComplete"] is False and result[-1]["errors"] > 0, f"{scenario}: incomplete, never success")
        check(any(r["record"] == "error" for r in result), f"{scenario}: concrete error")

print(f"PASS: {checks} read-only PF inventory checks (host, mocked ioctl, ASan/UBSan; device enforcement NOT_RUN)")
