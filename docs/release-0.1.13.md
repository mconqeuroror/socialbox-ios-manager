# RedditBox isolation sentinel release

Published rootless **0.1.13** and rootful **0.1.11** from `feat/lifecycle-and-distribution`; the branch remains unmerged. The feature commit is `9721c7ce1d5412aaed9a9a185f20ddcfdaa05021`.

- [Installation page](https://redditspoof.vercel.app/install)
- [Rootless Sileo source](https://redditspoof.vercel.app/apt/redditbox/)
- [Rootful Sileo source](https://redditspoof.vercel.app/apt/redditbox-rootful/)

Enable per container: **Edit → Show advanced groups → Isolation Sentinel → Save sentinel settings**, then reopen the clone. The observer is off by default and repeats every 15 minutes while iOS schedules the app, with a configurable interval and foreground checks. **Settings → Diagnostics → Isolation Sentinels** shows individual results. LEAK is displayed as FAIL and an Isolation alert; no sentinel result changes network admission. The optional clipboard write challenge is separately off by default.

Both ldid-only builds and their existing native/readiness tests passed without an Apple Development Team. New Security/Foundation/defaults/pasteboard mocks and OFF/ON registration fixtures passed, including found, absent, denied, inconclusive, stale, replay and missing-seed cases. Static checks and the 305-row leak-surface contract passed.

Both staging deployments passed signed APT/download validation and license health before promotion. Final production verification checked both signed repositories, every retained download, displayed versions, canonical Sileo links, the existing public Blob host, and the unchanged license public key. The shared publication lock was retained through normal resume/retry; no forced unlock or signature bypass was used. See `docs/release-evidence/0.1.13-distribution.json`.

On the attached iPhone (`iPhone10,4`, iOS 16.7.16), real IPC accepted valid settings, rejected malformed settings, delivered the clone-local root-owned control and restored OFF. Profile bytes, other container metadata, network generation/state and active license were preserved. The final production rootless package was installed and its launcher, tweak and daemon bytes matched the package. See `docs/release-evidence/0.1.13-sentinel-device.json` and `docs/release-evidence/0.1.13-final-install.json`.

**NOT_RUN:** actual sentinel probes inside a launched Reddit clone, A → B → A boundary acceptance, long-running/suspended periodic behavior, touchscreen appearance and rootful hardware acceptance. Only one clone is installed and managed per-app VPN remains deferred. Root SSH observations and host mocks do not establish cross-container isolation or 100% coverage.

The operator/probe contract and canary preparation are in `docs/isolation-sentinel.md`. Future changes must reference `LEAK_SURFACE.md` row **ACCEPT-005** and any enforcement rows they affect.
