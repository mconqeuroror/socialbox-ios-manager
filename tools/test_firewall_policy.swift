import Foundation

@main
struct FirewallPolicyTests {
    static func main() {
        let bundle = "com.redditbox.profile.p1234"
        let config: [String: Any] = ["scope": "per-app", "managedBundleIdentifiers": [bundle]]
        let lease: [String: Any] = ["state": "open", "generation": "g1", "bootEpoch": "boot1",
            "containerId": "c1", "bundleIdentifier": bundle, "heartbeatAt": 100.0,
            "expiresAt": 200.0, "proxyURL": "http://proxy.example:8080",
            "proxyIPs": ["203.0.113.5", "2001:db8::5"]]
        func policy(_ changes: [String: Any] = [:], now: Double = 101) -> FirewallPolicy {
            FirewallPolicy(lease: lease.merging(changes) { _, new in new },
                           configuration: config, now: now)
        }
        assert(policy().permits(host: "203.0.113.5", port: "8080", source: bundle))
        assert(policy().permits(host: "proxy.example", port: "8080", source: bundle))
        assert(!policy().permits(host: "203.0.113.5", port: "443", source: bundle))
        assert(!policy().permits(host: "reddit.com", port: "8080", source: bundle))
        assert(!policy().permits(host: "203.0.113.5", port: "8080", source: "com.reddit.Reddit"))
        assert(policy(["state": "closed"]).state == "closed")
        assert(!policy(["state": "armed"]).permits(host: "proxy.example", port: "8080", source: bundle))
        assert(policy(now: 102.5).state == "open")
        assert(policy(now: 102.5001).state == "closed")
        assert(policy(["heartbeatAt": Double.nan]).state == "closed")
        assert(policy(now: Double.infinity).state == "closed")
        assert(policy(now: 102.6).state == "closed")
        assert(policy(now: 99).state == "closed")
        assert(policy(["expiresAt": 100.5]).state == "closed")
        // A malformed infinite expiry must never produce an unbounded lease.
        assert(policy(["expiresAt": Double.infinity]).state == "closed")
        assert(policy(["expiresAt": -Double.infinity]).state == "closed")
        assert(policy(["expiresAt": Double.nan]).state == "closed")
        assert(policy(["heartbeatAt": Double.infinity]).state == "closed")
        assert(policy(["heartbeatAt": -Double.infinity]).state == "closed")
        assert(policy(now: Double.nan).state == "closed")
        assert(policy(now: -Double.infinity).state == "closed")
        assert(policy(["bootEpoch": ""]).state == "closed")
        assert(policy(["proxyIPs": ["proxy.example"]]).state == "closed")
        assert(policy(["proxyIPs": ["203.0.113.5", "malformed"]]).state == "closed")
        assert(policy(["proxyIPs": ["fe80::1%en0"]]).state == "closed")
        assert(policy(["proxyIPs": Array(repeating: "203.0.113.5", count: 33)]).state == "closed")
        assert(policy(["bootEpoch": "boot2"]) != policy())
        assert(policy(["proxyURL": "socks5://proxy.example:8080"]).state == "closed")
        assert(policy(["proxyURL": "https://proxy.example:8080"]).state == "closed")
        assert(policy(["proxyURL": "http://u%0a:p@proxy.example:8080"]).state == "closed")
        assert(policy(["proxyURL": "http://proxy.example:8080/path"]).state == "closed")
        let credentials = HTTPProxyEndpoint("http://u%40x:p%2540%3A%40@proxy.example:8080")!
        assert(credentials.username == "u@x" && credentials.password == "p%40:@")
        assert(HTTPProxyEndpoint("http://[2001:db8::5]:80")?.host == "2001:db8::5")
        assert(policy(["bundleIdentifier": "com.redditbox.profile.p5678"]).state == "closed")
        assert(FirewallPolicy(lease: lease, configuration: ["scope": "per-app"], now: 101).state == "closed")
        assert(FirewallPolicy(lease: lease, configuration: [:], now: 101).state == "closed")

        func query(_ host: String, type: UInt8 = 1) -> Data {
            var q: [UInt8] = [0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
            for label in host.split(separator: ".") { q += [UInt8(label.utf8.count)] + Array(label.utf8) }
            return Data(q + [0, 0, type, 0, 1])
        }
        let v4 = ProxyDNS.answer(query("proxy.example"), host: "proxy.example", addresses: ["203.0.113.5"])!
        assert(v4[7] == 1 && Array(v4.suffix(4)) == [203, 0, 113, 5])
        let v6 = ProxyDNS.answer(query("proxy.example", type: 28), host: "proxy.example", addresses: ["2001:db8::5"])!
        assert(v6[7] == 1 && v6.suffix(16).count == 16 && v6.last == 5)
        let denied = ProxyDNS.answer(query("reddit.com"), host: "proxy.example", addresses: ["203.0.113.5"])!
        assert(denied[3] & 15 == 3 && denied[7] == 0)
        assert(ProxyDNS.answer(Data([0, 1]), host: "proxy.example", addresses: []) == nil)
        var compressed = Array(query("proxy.example")); compressed[12] = 0xc0
        assert(ProxyDNS.answer(Data(compressed), host: "proxy.example", addresses: []) == nil)
        print("Firewall policy and local DNS tests passed")
    }
}
