# Saved identity fields and Random fill

Rows: UI-003, LIFE-029.

The old editor defaulted to automatic mode, disabling manual fields. Stable
identifiers were intentionally omitted from its world-readable status source,
so UUID/UDID fields appeared empty even for a populated profile.

The editor now loads the complete saved form over a separate private Keychain
item, bound to the request and container. The item is device-only, available
when unlocked, limited to 64 KiB, and accepted for five minutes. Only the latest
draft is retained; superseded or stale reads show an error and Reload. Public
state and IPC receipts carry no raw identifiers. License/proxy storage is a
separate item and is not modified by editor draft operations.

Random fill asks the existing generator/validator for a draft and fills the
fields. It preserves compatibility policies and does not apply a profile.
Check consistency and Save changes use the exact displayed manual identifiers;
edits invalidate preview approval. Frozen identities remain read-only, with an
explicit reason. Empty or failed loads cannot be saved.

Native private-channel tests cover readback, wrong request/container, stale and
future timestamps, locked Keychain, malformed/oversized records and separation
from saved licenses/proxies. Existing freeze and identity validation tests pass.
These host fixtures do not establish iPhone rendering or full isolation.

## Upgrade and device observations

After 0.1.6 upgrade, strict process inspection encountered a still-running old
RedditBoxFirewall executable whose replaced file no longer resolved through
proc_pidpath. A separate kernel snapshot and ps resolved that exact owned
companion process. Stopping it and restarting the daemon restored startup.
No process-inspection or traffic gate was relaxed.

The new preinst stops only exact resolved RedditBox and RedditBoxFirewall UI
executables before their files are replaced. It does not select packet-tunnel
provider or clone executables. Failed enumeration or refusal to stop aborts the
upgrade. Synthetic shell tests cover exact-path selection and failure handling.

On 0.1.6, the normal daemon successfully deleted our previously failed test
container with its existing journal, then created a fresh hidden clone from the
imported source. Opening that clone still requires its managed VPN association.
Full A/B isolation and login have not been established.
