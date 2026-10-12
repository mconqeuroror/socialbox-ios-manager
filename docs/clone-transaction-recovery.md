# C11 transaction recovery

Clone installation and recovery share a cross-process advisory lock. A version 2
journal is atomically written, read back, and fsynced before each phase proceeds:

| Phase | Meaning | Recovery |
| --- | --- | --- |
| prepared | Installer has not been invoked | Delete staging only; leave installed app and data untouched |
| install-attempted | Installer may have changed the installation | Identify this transaction, preserve its sandbox, restore previous app in place if needed |
| installed | New transaction marker and allocated containers verified | Same recoverable rollback until commit |
| committed | Installation and requested export completed | Remove staging; never uninstall |

Before replacing an existing app, stop and verify all clone processes, snapshot
and compare the sandbox, and archive the previous app. A failed preparation never
uninstalls anything. If recovery is needed, an existing installation is restored
by an in-place IPA install, without calling uninstall. A failed first install may
be uninstalled only when its marker identifies this transaction; its data is
copied out first, and disappearance is verified afterwards.

Recovery retains original and failed-install data under
`/var/mobile/Library/RedditBox/transactions/<UUID>/`. Completed rollbacks record
`recoveryState=complete` and retain both snapshots for manual data recovery.
Failed recovery retains the journal and backups, and blocks another install of
that bundle. Version 1 or malformed journals require manual recovery because
they do not establish whether the old installer was invoked. Legacy installations
are no longer deleted as a side effect of installing a replacement.

Device fault-injection checks (not executable on a Windows host):

- Fail staging, signing, archive creation and each prepared-journal write with an
  existing working app. Its registration, binary and user files must be unchanged.
- Kill the daemon immediately before and after invoking the installer, after
  `installed`, and after `committed`. Verify the phase-specific behavior above.
- Fail the installer after it replaces the app; fail IPA export. Verify the
  previous version is restored in place and its data contents are preserved.
- Fail restoration/uninstall, then restart repeatedly. Journal and snapshots
  remain; another installation of the bundle is refused.
- Kill recovery after data removal but before copy-back completes. The next
  recovery resumes from the retained original snapshot; failed-install data is
  still available independently.
- Change the installed marker to another transaction before recovery. Recovery
  must refuse to overwrite or uninstall that installation.

The existing installer/uninstaller helper compatibility finding remains phase 2.
A helper failure now stops recovery and preserves the artifacts instead of
discarding them.
