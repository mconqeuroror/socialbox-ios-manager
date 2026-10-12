# Checked global metadata writes

The `.5` private candidate replaces the pinned manager's
`writeGlobalMetadata:` and `mutateGlobalMetadataLocked:` methods with a
source-owned single-file transaction. This repairs **ADOPT-003** in part;
it is not a transaction across app data, keychain, processes and networking.

The recovered writer continues when opening its lock fails and does not check
`flock`. The mutator also falls back to an empty list when existing metadata
cannot be parsed. The replacement refuses both cases, preserves unknown plist
keys, and uses the original version-2 defaults only when the file is absent.
Both architecture IMPs and Objective-C encodings are mechanically checked by
`tools/verify_recovered_switch_site.py`, in addition to the app SHA and runtime
boundary checks. Foreign subclasses retain their original implementations.

Only the exact recovered rootless/rootful global metadata path is accepted.
The rootless bootstrap alias is resolved with `realpath`; every subsequent
directory is opened relative to a directory descriptor with `O_NOFOLLOW`.
The existing lock has a bounded half-second acquisition, owner/mode/type/link
checks and an inode recheck. Reads are bounded to 16 MiB and cannot block on a
FIFO. Corruption, symlinks, hardlinks and observed external replacement fail.

Mutation and serialization occur under the same lock. A unique temporary file
receives checked writes, preserved destination ownership/mode, and `fsync`.
The writer rechecks the destination, parent and lock before rename, then syncs
the directory. Failures before rename preserve the old file. Failure of the
directory sync returns NO and explicitly records that publication occurred with
unconfirmed durability; it does not claim rollback. Exceptions release all
descriptors and locks without logging potentially private exception text.

## Evidence

- 80 filesystem assertions reproduce the old lock failure and cover corruption,
  short/interrupted I/O, ENOSPC, lock contention, symlinks/hardlinks/FIFOs,
  externally replaced metadata, mutation exceptions and durability failures.
- Forty simultaneous mutations retain all forty distinct entries. Real child
  processes terminate just before and after rename; the next writer recovers
  the lock and observes a complete old or new file.
- 27 tests call the actual Objective-C replacements with mocked path/storage
  boundaries, including encoding/IMP/class/path rejection and no old fallback.
- All 80 + 27 assertions, plus the existing 175 per-app switch checks, pass on
  iPhone X / iOS 16.7.16. These are private fixture files and synthetic manager
  objects, not modifications of the user's real containers.
- The actual `.5` service boots, refuses an unrelated root caller and is
  stopped/unregistered. Both arm64 and arm64e are built with ldid; arm64e runtime
  and the installed original manager are not tested by those results.

See [the receipt](../../docs/release-evidence/global-metadata-2026-09-22.json).

## Remaining boundary

An advisory lock cannot fence a non-cooperating writer after the last check.
Per-app mirrors, target-engine and CLI/direct writers still require their own
acknowledged transaction boundary. Some outer workers ignore a returned NO.
No launch fence or network gate is added here. Same-ID fast success, global
worker error propagation and multi-file crash recovery remain separate work;
this row must stay a gap until those paths are integrated and device-tested.
