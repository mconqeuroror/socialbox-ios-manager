# Temporary private license console

The browser website currently exposes only the owner's license console and sign-in.
All UI remains English. The owner can create keys, view device activations and manage
existing keys; the default new key permits one activation. No customer keys, stored
passwords, container records or existing device entitlements are migrated by this change.

The owner is the existing configured seed identity: `ADMIN_EMAIL`, or
`ADMIN_USERNAME@redditbox.local` when no explicit email is configured (the existing
username fallback remains unchanged). An `admin` role alone is insufficient. The
middleware prefilters the signed cookie; the server-rendered admin layout and every
admin API then re-read the current user record and enforce the canonical owner and
current admin role. A stale role or changed stored identity cannot admit the console.

The login screen uses the new same-origin `/api/auth/owner-login` entry point.
Customer `/api/auth/login` and `/api/auth/register` remain available for native clients,
but their sessions cannot access the console unless they belong to the configured owner.
App/device activation, validation, backups and APT routes retain their contracts.

`/admin/releases`, `/updates`, `/install` and legacy app pages lead back to the license
console for the owner, and to sign-in for everybody else. The release source and API
are retained behind owner authorization; the release UI is dormant. The machine
`/api/releases/socialbox/latest` endpoint remains available. While this temporary mode
is active, `/updates` is not a public customer instruction page; re-enable that browser
route when public distribution is intentionally resumed.

## Verification

- `npm test`: existing license/device, concurrency, storage, profile, backup, APT and
  release suites, plus 10 owner-console groups with real handlers/disposable storage.
- `npm run build`: production Next.js build and type checking.
- `CLOUD_UI_OUTPUT=/tmp/console-proof PLAYWRIGHT_MODULE=/path/to/playwright
  CHROME_EXECUTABLE=/path/to/chrome node scripts/admin-console-ui-test.mjs`: starts
  the production build with a separate temporary database and synthetic credentials;
  tests owner/non-owner sign-in, hidden routes, forty records, search, key creation,
  clipboard/clear, 375px layout, fresh stored-role revocation and the machine update API.
  It never contacts production or uses real customer keys. Requires `npm run build` first.

The older release browser harness describes the retained dormant feature. It is not
an acceptance test of the current license-only browser navigation; release policy/API
regressions still run in `npm test`.
