# SocialBox binary recovery baseline

The owner supplied an installed-code/decompiler handoff and subsequently an IPA.
This unit reconstructs a deterministic **unvalidated binary recovery package**,
not original source code or the completed SocialBox integration. The original
licensing, hosted services, identity generation and runtime mechanisms remain.

`binary-baseline.json` identifies both inputs, every manifest payload file,
all 15 Mach-O components / 25 architecture slices, original entitlement and
injection declarations, decompilation coverage, and the generated package.
The IPA's 25 app-bundle files are byte-identical to the handoff; it contributes
no missing source, service, or library. The handoff contains 49 compiled/resource
files and three package-control files. All 52 SHA-256 checks and ZIP CRCs pass.

## Reproduce without executing imported code

Use Python 3.9 or newer from the repository root:

```sh
python3 tools/test_recover_socialbox_base.py
python3 tools/recover_socialbox_base.py /path/to/socialbox-3.1.0-1-developer-handoff.zip \
  --ipa /path/to/SocialBox-3.1.0-1-extracted.ipa.zip \
  --output /path/to/new-private-recovery-directory
```

The command accepts only the two hash-pinned supplied archives, validates paths,
CRC, the entire payload manifest, and indexed decompiler block addresses. It
reuses the repository's bounds-checked Mach-O parser to scan **all slices**. It
never runs archive scripts, starts the app, contacts a server, or installs a
package. The output directory must not exist. Local inputs and full structural
details remain private; only derived metadata is tracked in Git.

Outputs:

- `inventory.json`: deterministic structural summary and artifact hashes.
- `private-structural-inventory.json.gz`: every parsed selector/class/import,
  method-name string, and all supplied function-index rows. A reference is not
  proof of invocation or successful hooking. The inventory scans every retained
  slice; readable pseudocode in the input covers arm64 only.
- `socialbox-original-binary-recovery-unvalidated.deb`: surviving payload at its
  original rootless paths, with original postinst/prerm bytes and unchanged
  executable signatures. No binary is recompiled or re-signed. Tar ownership is
  reconstructed as root; file modes come from the ZIP. Original postinst sets
  privileged executable ownership/modes if later executed.

## Package differences and limits

The generated package retains `com.socialbox` and uses
`3.1.0-1+recovery.1`. Its package name/description explicitly say UNVALIDATED.
Its dependency floor is iOS 16 because the supplied snapshot lacks the legacy
FileProvider. Other original dependency declarations are retained. Checksums are
regenerated for the available 49 files; absent legacy files and personal runtime
configuration are not fabricated.

This is **not a byte-identical copy of the original .deb**. Original preinst,
postrm, triggers and conffiles are absent from the handoff. Their absence in the
handoff does not establish absence from the original release: the recovered
postinst explicitly refers to a preinst. Rootful and roothide builds are not
recovered by changing path strings.

Do not treat successful packaging as device acceptance. The original postinst
includes broad system-daemon operations, ownership changes, cleanup and an
unauthenticated dependency-install fallback. These bytes were preserved as
evidence, **not run or endorsed as the new release procedure**. App startup,
private entitlement enforcement, broker injection, server connectivity, old
container preservation and recovery on failure still need controlled device
tests. No update was installed over the existing phone setup.

No claimed isolation gap is closed by this unit. SocialBox's production hooks,
license root, network admission, source IPA caches, Cloud and release pipeline
are unchanged. The existing `LEAK_SURFACE.md` verdicts remain applicable to
SocialBox only; the recovered package has a separate, unverified runtime.

## Validation

- Six recovery tests: payload tampering, path aliases/unlisted payload,
  symlinks, IPA mismatch, deterministic package/script preservation and manifest.
- Actual handoff: CRC; 52 SHA-256 matches; all 18,025 exported pseudocode block
  addresses match indexed successful decompilations. 153 named auth/license
  functions are omitted from readable pseudocode and three routines unresolved;
  this is a coverage limitation, not evidence that licensing is absent.
- Actual generated package independently reopened: 49 payload hashes, both
  original scripts and regenerated md5sums match.
- Existing SocialBox static and native launch/firewall regression checks are
  recorded in the main adoption handoff. They do not validate SocialBox runtime.
