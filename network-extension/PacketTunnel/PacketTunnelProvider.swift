import NetworkExtension
import Darwin

// The existing bundle/product name is retained; its extension point is app-proxy.
final class PacketTunnelProvider: NEAppProxyProvider {
    private let policyQueue = DispatchQueue(label: "com.redditbox.firewall.policy")
    private var timer: DispatchSourceTimer?
    private var policy = FirewallPolicy()
    private var policyAppliedAt: TimeInterval = 0
    private var applying = false
    private var stopped = false
    private var relays: [UUID: TCPRelay] = [:]
    private var dnsFlows: [ObjectIdentifier: NEAppProxyUDPFlow] = [:]
    private var configuration: [String: Any] {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    }
    private var groupURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.redditbox.firewall")
    }
    private var denied: NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENETDOWN))
    }

    override func startProxy(options: [String: Any]? = nil,
                             completionHandler: @escaping (Error?) -> Void) {
        policyQueue.async {
            guard self.configuration["scope"] as? String == "per-app",
                  !(self.configuration["managedBundleIdentifiers"] as? [String] ?? []).isEmpty,
                  self.groupURL != nil else {
                completionHandler(self.denied); return
            }
            self.stopped = false
            self.setTunnelNetworkSettings(self.settings(for: FirewallPolicy())) { error in
                self.policyQueue.async {
                    guard error == nil, !self.stopped else {
                        completionHandler(error ?? self.denied); return
                    }
                    self.policyAppliedAt = Date().timeIntervalSince1970
                    self.publishStatus()
                    let timer = DispatchSource.makeTimerSource(queue: self.policyQueue)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                    timer.setEventHandler { [weak self] in self?.refreshPolicy() }
                    self.timer = timer; timer.resume()
                    completionHandler(nil)
                }
            }
        }
    }

    override func stopProxy(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        policyQueue.async {
            self.stopped = true
            self.timer?.cancel(); self.timer = nil
            self.closeAllFlows()
            self.policy.state = "closed"
            self.publishStatus(enforced: false)
            completionHandler()
        }
    }

    private func readPolicy() -> FirewallPolicy {
        let lease = groupURL.flatMap {
            NSDictionary(contentsOf: $0.appendingPathComponent("network-lease.plist"))
                as? [String: Any]
        } ?? [:]
        return FirewallPolicy(lease: lease, configuration: configuration)
    }

    private func refreshPolicy() {
        guard !stopped else { return }
        let next = readPolicy()
        if next != policy && !applying {
            // Revoke admission and both directions of all flows BEFORE CLOSED ACK.
            closeAllFlows()
            policy = next; policy.state = "closed"
            policyAppliedAt = 0
            applying = true
            setTunnelNetworkSettings(settings(for: next)) { error in
                self.policyQueue.async {
                    self.applying = false
                    guard !self.stopped else { return }
                    // An obsolete async completion cannot reopen a revoked lease.
                    if error == nil && self.readPolicy() == next {
                        self.policy = next
                        self.policyAppliedAt = Date().timeIntervalSince1970
                    } else { self.policy.state = "closed"; self.policyAppliedAt = 0 }
                    self.publishStatus()
                }
            }
        }
        publishStatus()
    }

    private func settings(for next: FirewallPolicy) -> NETunnelNetworkSettings {
        let settings = NETunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.dnsSettings = NEDNSSettings(servers: ["192.0.2.53"])
        settings.dnsSettings?.matchDomains = [""]
        if let endpoint = HTTPProxyEndpoint(next.proxyURL), let numeric = next.proxyIPs.first {
            let proxy = NEProxyServer(address: numeric, port: endpoint.port)
            proxy.authenticationRequired = !endpoint.username.isEmpty
            if proxy.authenticationRequired {
                proxy.username = endpoint.username
                proxy.password = endpoint.password
            }
            let proxies = NEProxySettings()
            proxies.httpEnabled = true; proxies.httpServer = proxy
            proxies.httpsEnabled = true; proxies.httpsServer = proxy
            proxies.excludeSimpleHostnames = false; proxies.matchDomains = [""]
            settings.proxySettings = proxies
        }
        return settings
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Taking ownership includes denied flows; they never fall back to a route.
        policyQueue.async {
            guard !self.stopped, !self.applying, self.readPolicy() == self.policy,
                  flow.metaData.sourceAppSigningIdentifier == self.policy.bundle else {
                self.close(flow); return
            }
            if let udp = flow as? NEAppProxyUDPFlow,
               ["armed", "open"].contains(self.policy.state) {
                self.startDNS(udp); return
            }
            guard let tcp = flow as? NEAppProxyTCPFlow,
                  let endpoint = tcp.remoteEndpoint as? NWHostEndpoint,
                  self.policy.permits(host: endpoint.hostname, port: endpoint.port,
                                      source: flow.metaData.sourceAppSigningIdentifier),
                  self.relays.count < 256 else { self.close(flow); return }
            let admitted = self.policy
            // Provider-native connections use the physical network. Only the
            // exact proxy port and an already validated numeric address are used.
            let address = admitted.proxyIPs.contains(endpoint.hostname)
                ? endpoint.hostname : admitted.proxyIPs[0]
            let upstream = self.createTCPConnection(
                to: NWHostEndpoint(hostname: address, port: String(admitted.proxyPort)),
                enableTLS: false, tlsParameters: nil, delegate: nil)
            let relay = TCPRelay(flow: tcp, upstream: upstream, queue: self.policyQueue,
                allowed: { [weak self] in
                    guard let self = self else { return false }
                    return !self.stopped && !self.applying && self.policy == admitted &&
                        self.readPolicy() == admitted
                }, finished: { [weak self] id in self?.relays.removeValue(forKey: id) })
            self.relays[relay.id] = relay; relay.start()
        }
        return true
    }

    private func close(_ flow: NEAppProxyFlow) {
        flow.closeReadWithError(denied); flow.closeWriteWithError(denied)
    }

    private func closeAllFlows() {
        for relay in Array(relays.values) { relay.close(denied) }
        for flow in dnsFlows.values { close(flow) }
        dnsFlows.removeAll()
    }

    private func startDNS(_ flow: NEAppProxyUDPFlow) {
        guard dnsFlows.count < 32 else { close(flow); return }
        let admitted = policy
        dnsFlows[ObjectIdentifier(flow)] = flow
        flow.open(withLocalEndpoint: nil) { error in
            self.policyQueue.async {
                if error != nil { self.finishDNS(flow); return }
                self.readDNS(flow, admitted: admitted)
            }
        }
        policyQueue.asyncAfter(deadline: .now() + 10) { self.finishDNS(flow) }
    }

    private func finishDNS(_ flow: NEAppProxyUDPFlow) {
        if dnsFlows.removeValue(forKey: ObjectIdentifier(flow)) != nil { close(flow) }
    }

    private func readDNS(_ flow: NEAppProxyUDPFlow, admitted: FirewallPolicy) {
        guard !stopped, !applying, dnsFlows[ObjectIdentifier(flow)] != nil,
              policy == admitted, readPolicy() == admitted else { finishDNS(flow); return }
        flow.readDatagrams { datagrams, endpoints, error in
            self.policyQueue.async {
                guard self.dnsFlows[ObjectIdentifier(flow)] != nil,
                      self.policy == admitted, self.readPolicy() == admitted,
                      error == nil, let datagrams = datagrams, let endpoints = endpoints,
                      !datagrams.isEmpty, datagrams.count == endpoints.count else {
                    self.finishDNS(flow); return
                }
                var replies: [Data] = []
                for (data, endpoint) in zip(datagrams, endpoints) {
                    guard let host = endpoint as? NWHostEndpoint,
                          host.hostname == "192.0.2.53", host.port == "53",
                          let answer = ProxyDNS.answer(data, host: admitted.proxyHost,
                                                       addresses: admitted.proxyIPs) else {
                        self.finishDNS(flow); return
                    }
                    replies.append(answer)
                }
                flow.writeDatagrams(replies, sentBy: endpoints) { error in
                    self.policyQueue.async {
                        if error != nil { self.finishDNS(flow) }
                        else { self.readDNS(flow, admitted: admitted) }
                    }
                }
            }
        }
    }

    private func publishStatus(enforced: Bool = true) {
        guard let url = groupURL?.appendingPathComponent("firewall-status.plist") else { return }
        let status: [String: Any] = [
            "providerBundleId": "com.redditbox.firewall.PacketTunnel",
            "state": policy.state, "generation": policy.generation,
            "bootEpoch": policy.bootEpoch, "containerId": policy.container,
            "bundleIdentifier": policy.bundle, "enforced": enforced,
            "scope": "per-app", "transport": "app-proxy",
            // Credentials are configured for OS-brokered requests, but a separate
            // OAuth process still needs verified managed mapping (phase 3 H08).
            // Configuring credentials alone is not evidence of that mapping.
            "outOfProcessAuthCovered": false,
            "heartbeatAt": Date().timeIntervalSince1970,
            "policyAppliedAt": policyAppliedAt,
        ]
        if !(status as NSDictionary).write(to: url, atomically: true) {
            closeAllFlows(); policy.state = "closed"
        }
    }
}
