# RedditBox modern identity editor and launch guidance

Branch: `feat/lifecycle-and-distribution` (unmerged).
Affected contract rows: UI-001, UI-003, ID-003, LIFE-023, LIFE-029.

## Behavior

- The catalog now contains 21 models, including iPhone 15/16/17 families,
  iPhone 16e/17e and iPhone Air, with 59 model/OS combinations.
- iOS 18.6.2 and 26.6.2 templates are available where the model supports them.
  Pickers show newer choices first and do not offer an OS older than the new
  model's minimum. They are reported identities, not physical OS upgrades.
- Model selection prepares a coherent private draft. Random fill keeps the
  selected model and OS. Check consistency and Save remain explicit, and
  identity freeze after first use remains enforced.
- Every editor field and compatibility switch has an inline explanation.
  Region, language, carrier and city have catalog choices.
- New models use explicit generic synthetic identifier templates. No guessed
  Apple retail SKU, IMEI TAC or manufacturer UDID prefix is copied from older
  models. IMEI is intentionally empty for these templates and the UI explains
  why. Empty IMEI/SKU answers replace stale MobileGestalt overrides and stay
  explicit, rather than falling through to the physical values.
- Open refreshes the setup snapshot and directs the operator to Settings when
  managed VPN is missing. Settings explains MDM and the required steps. The
  daemon remains authoritative; no network or license gate was bypassed.

## Evidence limits

Apple simulator profile excerpts/hashes and web sources are in
`device-catalog-evidence.json`. Screen/product/regulatory values are copied
from Apple's profiles; board suffix, RAM class and Darwin version-family
mappings are identified as inferences. These are synthetic templates, not
proof that an older iPhone can emulate every API or capability of newer models.
Existing six model identifier templates are preserved, not newly certified.

The connected phone's prior launch receipt rejected missing firewall CLOSED
acknowledgement. Its setup state was `not-configured`, with traffic closed.
That receipt does not establish a separate Reddit crash. Full launch and
cross-container acceptance require the missing managed VPN/MDM setup.

## Validation

The native catalog regression first failed because iPhone 17 Pro was absent,
then passed all 59 shipped tuples using the production generator/validator.
Explicit selected tuples are retained, invalid model/OS combinations fail,
and generic unavailable fields cannot revive stale MG answers. Existing
catalog failure handling, identity editor and operator wording checks pass.
Both release builds run the full required native/host checks.

Touchscreen taps/rendering, rootful device execution, managed clone launch,
login and full A/B isolation are not covered by those checks.

## Published and installed results

Production verification passed for rootless **0.1.11** and rootful **0.1.9**.
Both signed indexes, every retained package, exact local metadata, displayed
versions and both canonical Sileo links were checked. Staging license health
was observed successfully before promotion for each variant. The existing
cloud signer still matches the existing public key; private/license stores
were not replaced. Both publication journals reached `complete` through
same-owner resumes after transient lock/index visibility failures.

- Install page: https://redditspoof.vercel.app/install
- Rootless source: https://redditspoof.vercel.app/apt/redditbox/
- Rootful source: https://redditspoof.vercel.app/apt/redditbox-rootful/

Rootless 0.1.11 was transferred to the connected phone with matching SHA-256
and installed over 0.1.10. Startup completed, recovery remained empty and the
existing license stayed active. The production daemon and private Keychain
channel passed: load saved values; twice generate a draft for iPhone 17 Pro /
iOS 26.6.2 while preserving that choice; reject 17 Pro / 17.5.1; validate the
exact draft; prove Random fill alone did not save; save through the normal
clone rebuild; reload the same nine nonempty identifier fields and the
intentionally empty IMEI. No raw identifiers appeared in public state or
safe receipts. The daemon remained running.

These are SSH/backend device tests, not touchscreen rendering or successful
clone launch. The phone still reports managed VPN `not-configured` and
network `closed`. No additional recovery markers were retired for this update.
Public, redacted records are in `release-evidence/0.1.11-*.json`.

## Change commits

- `60be934`: modern catalog, coherent selected drafts and field explanations.
- `9d493b4`: setup guidance before Open, with a direct Settings action.
- `dea918b`: signed rootless 0.1.11 metadata.

Rootful metadata and final acceptance evidence are committed with this note.
No branch merge was performed.
