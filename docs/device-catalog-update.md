# Device catalog review — 2026-09-14

The catalog retains all 21 existing models and all 59 existing model/iOS choices.
It adds 100 choices using six public releases: iOS 18.7.8, 26.5, 26.5.1, 26.5.2,
26.6 and 26.6.1. The iPhone 17, 17 Pro, 17 Pro Max, Air and 17e templates each
now have five choices. No stored profile is rewritten by this data update.

Version, build and eligible product identifiers come directly from the
[Apple Software Lookup Service](https://gdmf.apple.com/v2/pmv). Apple documents
that service as its source for available releases and model applicability in
[Deploying software updates using declarative management](https://developer.apple.com/documentation/devicemanagement/deploying-software-updates-using-declarative-management).
The reviewed response SHA-256 and selected records are retained in
[device-catalog-evidence.json](device-catalog-evidence.json). Selection uses exact
version/build records in `AssetSets.iOS`; their supported device lists are
intersected with existing catalog models. Feed posting dates are not presented
as original release dates. This is a static synthetic profile catalog, not an
installer or a guarantee that Apple still signs any particular firmware.

That model-level check matters: the reviewed 26.5 build applies to the existing
13–16e templates, while 26.5.1 applies to the five 17-family/Air templates.
18.7.8 applies to the 13–16e templates, so it is not offered on a model whose
minimum system is iOS 26. The stable latest entry remains
[iOS 26.6.2, build 23G90](https://developer.apple.com/news/releases/?id=09082026a),
also listed on [Apple security releases](https://support.apple.com/en-us/100100).

Every model minimum was checked against Apple's installed CoreSimulator 381.1
device profile. Missing minimum fields on the six original model records were
filled from `minRuntimeVersion`; hashes and values are recorded in the evidence
file. This is a simulator template floor. It is not a statement that every
firmware above that number was released for that hardware.

Darwin releases remain explicitly identified as version-family inferences:
18.7.8 uses 24.6.0, 26.5.x uses 25.5.0, and 26.6.x uses 25.6.0. Apple Software
Lookup does not supply a kernel release. No matching physical firmware kernel
measurement was obtained during this review. The existing simulator-derived
RAM and board-name limitations remain; no new RAM, hardware identifier, IMEI
TAC, retail SKU or Apple UDID prefix was invented.

[iOS 27.0 build 24A435](https://developer.apple.com/news/releases/?id=09092026a)
is listed by Apple as an RC and is excluded. Apple has published specifications
for [iPhone 18 Pro / Pro Max](https://www.apple.com/iphone-18-pro/specs/) and
[iPhone Duo](https://www.apple.com/iphone-duo/specs/), but the installed device
profiles do not contain those models. Required hardware identifiers, memory
facts and the Duo display representation remain unverified, so those templates
are deferred rather than assembled from guesses.

One existing discrepancy is preserved for compatibility: iPhone 14 Plus uses
`D27AP`, while its Apple simulator profile has product class `D28`. Changing the
catalog value alone would invalidate existing profiles that the current
consistency validator checks against it. Correcting that legacy template needs
a separate versioned compatibility decision. It is recorded as a discrepancy,
not newly verified hardware evidence.

Validation: `tools/test_device_catalog_data.py` checks saved template fields and
choices, exact release applicability, minimums, build/Darwin dependencies and RC
exclusion. The native `tools/test_device_catalog.sh` exercises the shipped loader,
generator and consistency validator across every offered model/iOS tuple.
