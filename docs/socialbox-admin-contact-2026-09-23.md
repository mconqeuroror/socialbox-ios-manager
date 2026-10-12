# SocialBox owner admin and contact — 23 September 2026

The existing production site now opens a private license administration page at
<https://redditspoof.vercel.app/admin>. The old public landing, installation and
app dashboard pages redirect there. Signed-out visitors see only the SocialBox
login. The owner can create keys, copy newly issued keys once, search and filter
saved keys, and expand a key to manage devices, expiry, ownership and revocation.
Existing API authorization remains authoritative; the web UI is not an access
control boundary. Registration is no longer offered in the website UI.

The source-owned iPhone Home and Settings screens have a **Contact ·
@sctweaks** action. A tap opens Telegram's public username link, with its
HTTPS equivalent as fallback. It never sends a message, diagnostic information
or an identity automatically. The web footer opens the same public profile.
Visible reviewed static branding uses SocialBox; internal service names, cookie
names, archive protocols and original licensing remain compatible with the
preserved backend. Unknown server prose and unsupported original screen shapes
have not all been observed on the physical phone.

## Release evidence

- Production build and all pre-existing cloud test suites pass. Thirteen new
  routing/default-password checks and fourteen browser checks pass. Browser
  creation/revocation checks use mocked APIs and synthetic keys, not real users.
- The staging deployment accepted the existing owner login and returned the
  existing key list without plaintext keys. Exactly one existing admin account
  was observed. No live key was created, revoked or deleted for this check.
- The same checked deployment was promoted to the existing production domain.
  Anonymous admin API reads return 403. Signed-out admin/old website routes
  redirect to login. The shared APT publication lock was released afterward.
- All sixteen rootless/rootful APT metadata files and both public source
  archives remain byte-identical. This release does not publish the private
  recovered candidate through Sileo; existing APT versions remain 0.1.25.
- The `.11` native candidate builds for arm64 and arm64e with ldid. All 99
  workspace assertions and seven package composition tests pass. SSH installation
  on iPhone X / iOS 16.7.16 verified all 59 payload hashes and unchanged global
  container metadata; a private recovery package was retained.

See the [sanitized release receipt](release-evidence/socialbox-admin-contact-2026-09-23.json).
The `.10` receipt remains a historical build-only result; `.11` is installed.

## Remaining acceptance boundaries

Physical foreground navigation and tapping Contact in the original manager
remain NOT_RUN. A successful `uiopen` exit is not proof of displayed UI; only
the helper's module mapping was observed, and screenshotr was unavailable.

The recovered app still uses its original license consumers. The existing web
signer and those consumers have different pins and signed message contracts;
new web keys are **not established as activating the recovered candidate**.
ADOPT-004 tracks that integration. No license bypass or signer replacement is
part of this release. ADOPT-003's unfinished switching/network isolation work
also remains open; UI, installation and web tests do not establish isolation.
