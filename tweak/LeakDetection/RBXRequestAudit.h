#import <Foundation/Foundation.h>

// Feature 2.3 + 2.4 (tweak side) — request audit.
// Hooks NSURLSession dataTask creation; when the host contains reddit.com it
// records {containerId, host, time, proxyId} into the requests ring buffer of
// the central store (capped 500) and captures the request User-Agent into the
// container's fingerprint.userAgent for the daemon-side fingerprint registry.

void RBXInstallRequestAudit(void);
