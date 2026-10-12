import Foundation
import Darwin

// Value used by both admission and every asynchronous relay callback. Heartbeat
// timestamps are checked on every read but deliberately excluded from equality.
struct FirewallPolicy: Equatable {
    private static func numericAddress(_ text: String) -> Bool {
        // Darwin accepts scoped IPv6 text; leases require unscoped numeric addresses.
        guard !text.isEmpty, !text.contains("%"), text.utf8.count < Int(INET6_ADDRSTRLEN) else { return false }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }
    var state = "closed"
    var generation = "missing"
    var bootEpoch = ""
    var container = ""
    var bundle = ""
    var proxyURL = ""
    var proxyHost = ""
    var proxyPort = 0
    var proxyIPs: [String] = []

    init(lease: [String: Any] = [:], configuration: [String: Any] = [:],
         now: TimeInterval = Date().timeIntervalSince1970) {
        generation = lease["generation"] as? String ?? "missing"
        bootEpoch = lease["bootEpoch"] as? String ?? ""
        container = lease["containerId"] as? String ?? ""
        bundle = lease["bundleIdentifier"] as? String ?? ""
        let requested = lease["state"] as? String ?? "closed"
        let heartbeat = lease["heartbeatAt"] as? TimeInterval ?? 0
        let expiry = lease["expiresAt"] as? TimeInterval ?? 0
        let age = now - heartbeat
        let bundles = configuration["managedBundleIdentifiers"] as? [String] ?? []
        guard now.isFinite, heartbeat.isFinite, expiry.isFinite,
              !bootEpoch.isEmpty, !generation.isEmpty, age >= 0, age <= 2.5,
              configuration["scope"] as? String == "per-app", !bundles.isEmpty,
              ["armed", "open"].contains(requested), !container.isEmpty,
              bundle.hasPrefix("com.redditbox.profile.p"), bundles.contains(bundle),
              now < expiry,
              let text = lease["proxyURL"] as? String, let endpoint = HTTPProxyEndpoint(text),
              let ips = lease["proxyIPs"] as? [String], !ips.isEmpty, ips.count <= 32,
              ips.allSatisfy(Self.numericAddress) else { return }
        state = requested
        proxyURL = text
        proxyHost = endpoint.host
        proxyPort = endpoint.port
        proxyIPs = ips.sorted()
    }

    func permits(host: String, port: String, source: String) -> Bool {
        state == "open" && source == bundle && Int(port) == proxyPort &&
            (host.lowercased() == proxyHost || proxyIPs.contains(host))
    }
}
