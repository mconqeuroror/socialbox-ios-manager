# iPhone CONNECT authentication correction — 2026-09-11

On the USB-connected iPhone running RedditBox 0.1.4, the saved configuration test reported `cancelled`, with an active license and a successful Reddit 2026.36.0 source import. No containers were present.

A bounded standalone Objective-C probe compiled with the shipped RBXHTTPProxy implementation reproduced the failure on that phone: the task-level challenge was marked as a proxy challenge, with HTTPS proxy type, the configured proxy port, HTTP Basic and zero prior failures, but its host was the request destination `ipinfo.io`. The old strict proxy-host comparison canceled it and NSURLSession returned NSURLErrorDomain -999. The same supplied proxy succeeded with curl from the Mac.

The correction accepts this iOS alias only when the challenge belongs to the current HTTPS task destination and the session uses the exact generated single-proxy PAC. The configured proxy port, supported authentication type, first-attempt limit and live endpoint remain mandatory. Origin challenges never receive proxy credentials. No DIRECT fallback or TLS trust override was added.

The regression failed before the correction and passed afterward. Negative fixtures cover a direct session, another task destination, taskless session alias, wrong proxy authority/port, repeated authentication and revoked credentials. Recompiling the phone probe with the correction produced HTTP 200 and a valid IP response with normal TLS trust handling. This proves that specific phone-to-proxy request; it does not establish clone isolation, MDM/VPN enforcement or full application acceptance. Proxy credentials and the exact endpoint remain outside this report.

Evidence row: NET-038; its broader verdict remains unverified.
