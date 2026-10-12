#import <Foundation/Foundation.h>
@class RBXOperationContext;

// SocialBox encrypted cloud backup and device pairing.
//
// The encrypted archive carries app files and logical profile identity into a
// newly created local container. Keychain and hardware-bound keys are not
// exported; restored login and per-app VPN associations require device checks.
// Transfers share the existing account and current device license scope.
//
// Cloud plist (shared with the prefs "Cloud" pane):
//   /var/mobile/Library/Preferences/com.redditbox.cloud.plist
//     serverURL       — operator deployment URL (default RBXCloudProductionOrigin)
//     accessKey       — cloud-issued access key (Settings field; validated by RBXLicenseGuard)
//     deviceId        — from POST /api/devices/pair
//     deviceToken     — bearer token for the API
//     deviceName      — from the pairing response
//     passphrase      — generated on device (SecRandomCopyBytes); copied only by
//                       explicit operator action through the private Cloud UI;
//                       never included in HTTP, public receipts or diagnostics
//     expireDays      — backups older than this are skipped by "newest"
//                       selection (default 7)
//     allowStale      — allow imports older than 72h (default NO)
//     workerAttestPolicy — "re-attest" (authentic) or "off"
//
// Actions arrive as immutable request records through the daemon's serialized
// request controller. The configuration plist is never an action inbox.
// Prefs never does networking.
//
// Blob contract (must match cloud/):
//   passphrase -> PBKDF2-HMAC-SHA256 (600,000 iters, 16-byte random salt,
//   32-byte key) -> AES-256-GCM (12-byte random nonce, 16-byte tag, AAD
//   authenticated). CryptoKit's AES.GCM is Swift-only, so the daemon uses the
//   system libcommonCrypto SPI (CCCryptorGCMOneshotEncrypt/Decrypt) — same
//   algorithm, same wire format.
//   AAD = the exact JSON string {"v":1,"kdf":"PBKDF2-SHA256","iter":600000,"cipher":"AES-256-GCM"}
//   blob = salt(16) || nonce(12) || ciphertext || tag(16)
//   ciphertext encrypts: 4-byte big-endian manifest JSON length || manifest
//   JSON (UTF-8) || tar.gz of the container data dir.
//
// Encrypted transport: POST /api/backups/transfer starts/finalizes an upload;
// PUT sends each 1 MiB part. GET /api/backups/:id?transfer=1 returns metadata;
// append &part=N for authenticated ciphertext. No public download URLs.
//
// Legacy API contract remains readable (cloud/, /api):
//   POST /api/devices/claim {pairingCode}                -> {deviceId, token}
//   POST /api/backups {containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed?}
//                                                        -> {backupId}
//   GET  /api/backups?containerId=                       -> {backups:[...]}
//   GET  /api/backups/:id                                -> JSON envelope (ciphertext is opaque base64)
//   DELETE /api/backups/:id
// Pairing codes are created on the website (POST /api/devices/pair with a user
// JWT). The phone only claims. Ciphertext is never decrypted on the server.

NS_ASSUME_NONNULL_BEGIN

@interface RBXCloudSync : NSObject

// Singleton (used by the darwin-notification callback path in main.m).
+ (instancetype)sharedSync;

// Generates the passphrase on first run (pairing happens on operator action).
- (void)start;

// Main owns request serialization and keeps ownership until this single terminal
// completion, delivered on the cloud queue. Reads action/arguments only from the
// explicit record; unknown actions or malformed input complete with an error.
- (void)handleQueuedAction:(NSDictionary *)request
                completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)handleQueuedAction:(NSDictionary *)request context:(RBXOperationContext *)context
                completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

// True (and the stored token) when this device is paired.
- (BOOL)paired;
- (NSString *)deviceToken;

// The stored passphrase (generated at first start; never nil after start).
- (NSString *)passphrase;

// Re-generate the passphrase (prefs button). Pairing survives; blobs made with
// the old passphrase can no longer be decrypted on this device.
- (void)regeneratePassphrase;

// Server URL with fallback default.
- (NSString *)serverURL;
- (BOOL)setServerURL:(NSString *)serverURL error:(NSError **)error;
// Only the pinned-token verifier may publish a successful activation pairing.
// pairing includes captured serverURL plus verified deviceId/token/name/role.
- (BOOL)acceptLicensePairing:(NSDictionary *)pairing context:(RBXOperationContext *)context error:(NSError **)error;

// Pull console-created profiles assigned to this paired device. Missing local
// profiles are generated and cloned; existing local profiles remain unchanged.
- (void)syncProfileInventoryWithCompletion:
    (void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)syncProfileInventoryWithContext:(RBXOperationContext *)context
    completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

// Pull the user's encrypted global rotation settings and persist them in the
// launcher/daemon shared Keychain group. A missing cloud record leaves local
// launcher settings unchanged.
- (void)syncLauncherConfigurationWithCompletion:
    (void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)syncLauncherConfigurationWithContext:(RBXOperationContext *)context
    completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

// Fetch the paired device's persistent cloud proxy assignment and atomically
// apply it to the local profile. Missing/unhealthy assignments fail closed.
- (void)syncProxyAssignmentForContainer:(NSString *)containerId
                             completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)syncProxyAssignmentForContainer:(NSString *)containerId context:(RBXOperationContext *)context
                             completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

// Refresh an optional encrypted cloud-managed per-profile rotation header.
// A missing override is success and removes any stale local override.
- (void)syncRotationAuthForContainer:(NSString *)containerId
                          completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)syncRotationAuthForContainer:(NSString *)containerId context:(RBXOperationContext *)context
                          completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

- (void)reportProxyId:(NSString *)proxyId
               healthy:(BOOL)healthy
                message:(NSString * _Nullable)message;
- (void)reportProxyId:(NSString *)proxyId healthy:(BOOL)healthy
    message:(NSString * _Nullable)message context:(RBXOperationContext *)context;

// POST /api/devices/claim using the explicit pairing code argument.
- (void)pairWithCode:(NSString *)pairingCode
         completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)pairWithCode:(NSString *)pairingCode context:(RBXOperationContext *)context
         completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

// Build + upload a snapshot of the given container. Reads nickname/username
// from the central store, appVersion from RBXAppVersionMonitor, the seed from
// the container profile. Completion on a background queue.
- (void)exportContainer:(NSString *)containerId
             completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)exportContainer:(NSString *)containerId context:(RBXOperationContext *)context
             completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

// Import the newest (or exact-id) backup. All failure paths add a central
// store alert ("STALE BACKUP", "WRONG PASSPHRASE", "PROXY MISMATCH",
// "DUPLICATE RESTORE", "CLOUD ERROR") and never leave partial containers
// behind (extraction happens in a temp dir; the move into place is the last
// step after manifest validation + proxy check pass).
- (void)importNewestBackup:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)importNewestBackupWithContext:(RBXOperationContext *)context
    completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)importBackupWithId:(NSString *)backupId
                completion:(void (^)(BOOL ok, NSString * _Nullable message))done;
- (void)importBackupWithId:(NSString *)backupId context:(RBXOperationContext *)context
                completion:(void (^)(BOOL ok, NSString * _Nullable message))done;

@end

NS_ASSUME_NONNULL_END
