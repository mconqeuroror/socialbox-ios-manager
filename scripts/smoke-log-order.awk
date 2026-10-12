# Scope authorization evidence to one full request/generation and clone PID.
# Startup self-reports may precede control-state placement; final evidence wins.
{
    req = gen = pid = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^request=/) req = substr($i, 9)
        if ($i ~ /^generation=/) gen = substr($i, 12)
        if ($i ~ /^pid=/) pid = substr($i, 5)
    }
    if (req != request || gen != generation) next
    if ($0 ~ /HOOK READINESS VERIFIED/) {
        if (pid != clonePID || opened) invalid = 1
        ready = 1
    }
    if ($0 ~ /SYSTEM FIREWALL ACK state=open/) {
        if (!ready || opened) invalid = 1
        ack = 1
    }
    if ($0 ~ /NETWORK OPEN/) {
        if (!ready || !ack) invalid = 1
        opened = 1
    }
}
END {
    if (invalid || !ready || !ack || !opened) {
        print "FAIL: missing or out-of-order final readiness/OPEN acknowledgement for requested generation/PID" > "/dev/stderr"
        exit 1
    }
    print "PASS: matching final hook readiness precedes provider OPEN ACK, then NETWORK OPEN"
}
