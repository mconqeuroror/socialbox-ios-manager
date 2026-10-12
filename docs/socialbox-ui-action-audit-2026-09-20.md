# Launcher action audit — 2026-09-20

This pass follows the reference redesign through actual native action callbacks.
It preserves the daemon's selection, launch, replacement, deletion, license and
Cloud ownership checks. The fixture uses synthetic profiles and inert IPC; it
does not establish physical-device isolation or successful account login.

## Reproduced and repaired

1. **Simple recovery rows offered normal operations.** The simple container menu
   returned before the existing unreadable-profile, unfinished deletion and
   replacement recovery branches. Both replacement participants could therefore
   show ordinary Use/Configure actions. The shared recovery branches now run
   first. Opening a recovery choice remains read-only; retry deletion or resume
   replacement still needs its existing explicit confirmation. Home also refuses
   identity editing while a replacement is unfinished.
2. **Reddit “Account & license” opened the wrong screen.** It led to the separate
   anonymous Reddit username-status lookup. It now calls the existing app-scoped
   license route, with the Back button retained. The Facebook descriptor is also
   preserved by that method; Facebook's currently inactive workspace is not
   represented as a working five-tab interface.
3. **Blocked Home Open offered an indirect route.** It showed a generic error and
   advanced-mode entry instead of the setup destination. Home and advanced Open
   now share a dialog retaining the exact published block reason and an Open
   Settings action. Neither path queues a launch while blocked. The no-selection
   text correctly tells the operator to open from SocialBox.
4. **A delayed Cloud Copy callback retained a cleared private key.** The callback
   captured the original key string and could copy it after stale activation had
   cleared and dismissed its field. It now reads the weak displayed field,
   clears it, rechecks current activation, and copies only a valid remaining key.
   Authorized copies retain the existing local-only, one-minute expiry. Clearing
   the field/backgrounding can no longer be bypassed by the captured callback.
5. **Advanced role filtering hid recovery rows.** The old predicate retained
   deletion and unreadable-profile rows but filtered out unfinished replacements
   and isolation alerts belonging to another role. It now preserves all four
   recovery classes. Completed replacements and malformed/empty sentinel data
   are not promoted to alerts; normal role filtering and row order are preserved.

## Verification and evidence

- Failing-first actual UIKit run: 232 checks, eight failed assertions covering
  the original license destination, four recovery cases and blocked-Open route.
- Separate failing-first key callback run: 235 checks, one failed assertion for
  disclosure after activation became stale. The other repaired routes passed.
- Final actual UIKit run: **239 checks PASS, zero failures**. Result and recording
  are retained in the private workspace
  evidence directory `private-device/socialbox-ui-2026-09-20/ui-audit-verified/`
  and the adjacent `ui-audit-verified.mp4`. Blocked-Open and recovery screenshots
  were visually checked after waiting for the UIKit transitions. The fixture intercepts clipboard writes in
  process and never copies a real key to the Mac or iPhone clipboard.
- `tools/test_workspace_dispatch.py`: 177 assertions PASS.
- `tools/test_workspace_selection.sh`: 210 assertions PASS, including forty
  profiles, switch ordering, restart and interruption cases.
- `tools/test_workspace_role_filter.py`: 23 assertions PASS against the extracted
  production predicate. It failed first when a different role hid an unfinished
  replacement, then passed after the two recovery conditions were added. This
  final advanced-only change follows the recorded simple-workspace run.
- `tools/test_profile_rename.py`: 55 actual metadata assertions PASS.
- `tools/test_cloud_vault_bridge.py`: 93 actual private Cloud/transport assertions
  PASS. Malformed and foreign backup rows remain filtered in the daemon.
- `tools/test_settings_presentation.py`: 32 assertions PASS.
- `tools/test_creation_defaults.py`: 16 assertions PASS.
- Workspace projection, launcher architecture, launcher multi-app architecture,
  replacement architecture and `tools/static_check.py`: PASS.

The expanded workspace fixture keeps all prior 216 checks for fifty-row browsing,
forty daemon-confirmed selections, stale-state clearing, rename, explicit backup
confirmation, private receipts and Reddit Home/Containers creation entry. Added
checks exercise the repaired routes, recovery without mutation, scoped licensing,
authorized expiring key copy and stale callback rejection.

Related creation/proxy work is independently verified by its owner: actual
wizard 53 checks, creation dispatcher 251 checks and proxy import/selection 23
checks. Those are separate fixtures, not additional device acceptance evidence.

## Isolation register and remaining limits

Affected contract rows: **UI-005** (failure actions), **UI-007** (workspace
navigation), **UI-010** (Settings/Cloud presentation), **CLOUD-002** (private key
boundary). No change to clone identities, entitlements, app data, hooks, proxy
assignment, network gates, cloud authentication or replacement ordering.

Physical-device key lifecycle, live Cloud transfer, forty installed containers,
network capture and account login remain separate acceptance work. No new claim
of “100% isolation” follows from these UI results. Folders, manual ordering and
batch operations remain deferred because this pass supplies no authoritative
backend for them; no inactive controls were added.
