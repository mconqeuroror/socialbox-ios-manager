#import <Foundation/Foundation.h>

// Central shared store for RedditBox (tweak + daemon + prefs).
// Single JSON file inside the jailbreak prefs area, invisible to the Reddit app:
//   /var/mobile/Library/Preferences/com.redditbox.store.json
//
// Schema (v2):
// {
//   "device":   { "attestKeysUsed": [ {containerId, keyId, timestamp} ],
//                "keyBudget": 100, "attestDefault": "on" },
//   "containers": { "<id>": {
//       "nickname", "username", "status": "green|yellow|red",
//       "createdAt": 0, "diedAt": 0, "deathReason": "ban|shadowban|loginFail|other|",
//       "missionCompleted": false,
//       "attest": { "mode": "auto|on|off", "group": "A|B", "keyIds": [],
//                  "blocked": false, "duplicateKey": false },
//       "push": { "enabled": false, "token": null },
//       "fingerprint": { "bundleHash", "userAgent", "model", "locale", "timezone" },
//       "lastProxyId": "", "lastIP": "",
//       "lastHealth": { "checkedAt": 0, "code": 200,
//                       "result": "healthy|suspended|shadowbanned|unknown" },
//       "karma": 0, "paused": false,
//       "devicecheckUsed": false, "devicecheckAt": 0 } },
//   "health":   { "intervalSeconds": 21600, "calibrationMode": false,
//                "calibration": { "200": "healthy", "403": "suspended", "404": "shadowbanned" } },
//   "alerts":   [ {type, containerId, message, timestamp} ],   // capped: last 100
//   "requests": [ {containerId, host, time, proxyId} ]        // capped: last 500
// }
//
// Each instance serializes its read-modify-write operations and atomically
// replaces the file. The change notification refreshes readers; it does not
// provide a transaction across processes or independently allocated instances.

NS_ASSUME_NONNULL_BEGIN

@interface RBXCentralStore : NSObject

// Singleton used by tweak/daemon/prefs. Also safe to alloc/init directly.
+ (instancetype)sharedStore;

// Missing file has defaults. Existing corrupt/newer files return nil and are never reset.
- (nullable NSMutableDictionary *)dictionary;
- (nullable NSMutableDictionary *)dictionaryWithError:(NSError **)error;

// Read-modify-write: the block receives a mutable document; when the block
// returns, the document is persisted atomically to disk and the
// "com.redditbox.storeChanged" darwin notification is posted.
- (void)update:(void (^)(NSMutableDictionary *doc))block;
// Checked publication for operations whose success depends on persistence.
// An unreadable/corrupt existing document is an error, never an empty store.
- (BOOL)update:(void (^)(NSMutableDictionary *doc))block error:(NSError **)error;

// Path of the backing file.
+ (NSString *)storePath;

#pragma mark - Alerts

// Append an alert (capped at 100, newest last). type examples:
// "PUSH LEAK", "IP LINK", "DUPLICATE KEYID", "KEY BUDGET", "FRESH ACCOUNT BANNED".
- (void)addAlertType:(NSString *)type
         containerId:(nullable NSString *)containerId
             message:(NSString *)message;

// True if an alert of the given type for the container already exists
// (used to avoid duplicate spam for threshold-style alerts).
- (BOOL)hasAlertType:(NSString *)type containerId:(nullable NSString *)containerId;

- (NSArray<NSDictionary *> *)alerts;

#pragma mark - Requests ring buffer

// Append {containerId, host, time, proxyId}; buffer keeps the last 500 entries.
- (void)addRequestForContainer:(NSString *)containerId
                          host:(NSString *)host
                       proxyId:(nullable NSString *)proxyId;

- (NSArray<NSDictionary *> *)requests;

#pragma mark - Containers

// Dictionary for the container (created if missing inside the returned snapshot).
// NOTE: this is a read snapshot — persist changes with -update:, e.g.
//   [store update:^(NSMutableDictionary *doc) { doc[@"containers"][id][...] = ...; }];
- (NSMutableDictionary *)container:(NSString *)containerId;

// Convenience: prune containers dictionary of entries that are not dictionaries.
- (void)pruneInvalidContainers;

// Effective attest decision for a container:
//   "on"  -> attestation allowed (calls pass through)
//   "off" -> attestation disabled (app sees DeviceCheck-style errors)
// Resolution order (per spec): container mode on|off wins; "auto" falls back to
// the A/B group default (A=on, B=off); missing/invalid falls back to the global
// device.attestDefault.
- (NSString *)effectiveAttestModeForContainer:(NSString *)containerId;

#pragma mark - Key registry

// Number of distinct attestation keys recorded for the device.
- (NSInteger)attestKeyCount;

// Record {containerId, keyId, timestamp} into device.attestKeysUsed (source of
// truth for the budget tracker). Deduplicates identical (containerId,keyId) pairs.
- (void)recordAttestKeyForContainer:(NSString *)containerId keyId:(NSString *)keyId;

// All keyIds ever seen for this container (attest.keyIds), as strings.
- (NSArray<NSString *> *)keyIdsForContainer:(NSString *)containerId;

// Record a keyId observed for a container (attest/generateAssertion observation).
- (void)observeKeyForContainer:(NSString *)containerId keyId:(NSString *)keyId;

// If the keyId is already used by a DIFFERENT container, mark the given container
// blocked + duplicateKey, add a "DUPLICATE KEYID" alert, return YES.
- (BOOL)markDuplicateKeyIfUsedElsewhere:(NSString *)containerId keyId:(NSString *)keyId;

// True when the container's attest is blocked (duplicate key / operator block).
- (BOOL)attestBlockedForContainer:(NSString *)containerId;

#pragma mark - Threshold helpers

// Budget warnings: adds "KEY BUDGET" alerts only when a threshold is newly
// crossed (>=80% yellow, >=95% red, of device.keyBudget, default 100).
- (void)evaluateKeyBudget;

@end

NS_ASSUME_NONNULL_END
