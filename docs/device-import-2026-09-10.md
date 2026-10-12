# iPhone source-import check — 2026-09-10

Target: iPhone 8 (`iPhone10,4`), iOS 16.7.16, palera1n rootless,
Debian architecture `iphoneos-arm64`. This is a partial device check, not
acceptance of all jailbreaks or clone/network behavior. The branch remains unmerged.

## Observed failure and fix

The previous 0.1.1 daemon was terminated with
`JETSAM_REASON_MEMORY_PERPROCESSLIMIT` during source extraction. Launchd
reported a 6 MB configuration; the kernel memory-limit API reported an actual
18 MiB active/inactive cap. A plist memory hint alone did not change that cap
on this bootstrap.

The daemon now raises smaller positive active/inactive caps to 256 MiB through
Darwin's memory-status API before Foundation initialization. It preserves
larger/unlimited limits and existing kill attributes, reads the result back,
and logs unsupported/denied changes. The ABI uses commands 7 and 8 from
[Apple XNU kern_memorystatus.h](https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.61.2/bsd/sys/kern_memorystatus.h).
Per-entry autorelease pools bound temporary Foundation objects during ZIP
extraction and nested executable validation.

After installation of the 0.1.2 candidate, a separate kernel query reported
256 MiB before making any change. The same daemon PID survived the complete
source import. The terminal IPC receipt succeeded, the published source state
reported `found=true`, `decrypted=true`, `location=private-cache`, Reddit
2026.36.0 / build 664762, and the device license remained active. Startup
recovery succeeded and no operation recovery fence remained.

The initial dump decrypted only Reddit's main executable; four extensions
remained encrypted. A complete device dump was checked for ZIP integrity and
all eight Mach-O files; no encrypted slice remained. The private IPA is not
part of the source repository or public package distribution.

## Recovery and diagnostics limits

Before recovery, device data, settings and the partial import were backed up.
There were no profiles or published source. With the daemon unloaded, the
specific interrupted import, unchanged central store and lack of owned child
work were verified. Its partial stage and active journal were moved together
to a private recovery directory, not deleted. This does not implement or
validate general automatic recovery (H12 remains open).

This bootstrap has neither a stock nor rootless `log` executable. Support-log
export therefore failed before spawning a child. Export now checks both paths
and gives an explicit USB-log collection message if neither exists; it does
not report a successful export. Other spawn failures include the executable
name and OS error. USB log collection was available on the connected Mac. A final-package device
request confirmed that the missing-tool case produces this explicit failure,
with no falsely successful export or operation fence.

A subsequent same-version reinstall exposed a separate upgrade limitation:
the already-running RedditBox Firewall host retained its removed executable.
`proc_pidpath` returned ENOENT for that live host, so the daemon correctly
refused to claim that all Reddit processes had stopped. The exact PID and
full RedditBox Firewall path were verified, that stale host was terminated,
and the idle daemon restarted. Startup recovery then passed again, with the
source and license intact. The check was not relaxed to ignore arbitrary
unreadable live processes. Automatic handling of a running host during package
upgrade remains unimplemented.

## Still untested

- Dopamine and palera1n rootful installation/runtime.
- Clone creation, replacement, deletion, hook injection and Reddit login.
- MDM adoption, per-app VPN association, proxy routing and traffic isolation.
- Upgrade preservation with existing profiles and all remaining acceptance cases.

The connected device had no proxy configuration and its network state remained
closed. Successful source import is not evidence of a working isolated clone.
