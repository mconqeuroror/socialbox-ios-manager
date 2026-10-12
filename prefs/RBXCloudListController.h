#import <Preferences/Preferences.h>

// Legacy cloud preferences pane; not part of the shipped preferences target.
//
// All actions are handed to the daemon via the cloud plist + the
// "com.redditbox.cloudAction" darwin doorbell (prefs never does networking).
// Fields:
//   - Server URL (PSTextField, persisted in com.redditbox.cloud.plist)
//   - Access Key (cloud-issued key that unlocks RedditBox)
//   - License status line
//   - Pairing code field + "Pair device" button
//   - Device status line (paired name/id or "Not paired")
//   - Passphrase display (copyable readonly text)
//   - "Regenerate passphrase" button
//   - "Export active container" button (+ optional container id override field)
//   - "Import newest backup" button
//   - Backup ID field + "Import by ID" button
//   - "Allow stale imports (>72h)" switch
//   - "Worker attest policy: re-attest" switch (ON = re-attest, OFF = off)

@interface RBXCloudListController : PSListController

@end
