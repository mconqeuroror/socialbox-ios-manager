import NetworkExtension
import Darwin

// This forwards an already-proxied TCP stream to exactly the authorized proxy.
// The app's existing proxy implementation owns CONNECT/SOCKS authentication/TLS.
// All methods and callbacks run on the provider's policy queue.
final class TCPRelay {
    let id = UUID()
    private let flow: NEAppProxyTCPFlow
    private let upstream: NWTCPConnection
    private let queue: DispatchQueue
    private let allowed: () -> Bool
    private let finished: (UUID) -> Void
    private var observation: NSKeyValueObservation?
    private var closed = false
    private var opened = false
    private var readEOF = false
    private var writeEOF = false

    init(flow: NEAppProxyTCPFlow, upstream: NWTCPConnection, queue: DispatchQueue,
         allowed: @escaping () -> Bool, finished: @escaping (UUID) -> Void) {
        self.flow = flow; self.upstream = upstream; self.queue = queue
        self.allowed = allowed; self.finished = finished
    }

    func start() {
        observation = upstream.observe(\.state, options: [.initial, .new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.queue.async { self.connectionChanged() }
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, !self.opened else { return }
            self.close(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)))
        }
    }

    func close(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        observation = nil
        upstream.cancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        finished(id)
    }

    private func valid() -> Bool {
        guard !closed else { return false }
        if !allowed() { close(); return false }
        return true
    }

    private func connectionChanged() {
        guard valid() else { return }
        switch upstream.state {
        case .connected:
            guard !opened else { return }
            opened = true
            flow.open(withLocalEndpoint: nil) { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    guard self.valid() else { return }
                    if let error = error { self.close(error); return }
                    self.readApp(); self.readProxy()
                }
            }
        case .cancelled, .disconnected: close(upstream.error)
        default: break
        }
    }

    private func readApp() {
        guard valid() else { return }
        flow.readData { [weak self] data, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.valid() else { return }
                if let error = error { self.close(error); return }
                guard let data = data, !data.isEmpty else {
                    self.readEOF = true; self.upstream.writeClose()
                    if self.writeEOF { self.close() }; return
                }
                self.upstream.write(data) { error in
                    self.queue.async {
                        if let error = error { self.close(error) }
                        else { self.readApp() }
                    }
                }
            }
        }
    }

    private func readProxy() {
        guard valid() else { return }
        upstream.readMinimumLength(1, maximumLength: 65536) { [weak self] data, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.valid() else { return }
                if let error = error { self.close(error); return }
                guard let data = data, !data.isEmpty else {
                    self.writeEOF = true; self.flow.closeWriteWithError(nil)
                    if self.readEOF { self.close() }; return
                }
                self.flow.write(data) { error in
                    self.queue.async {
                        if let error = error { self.close(error) }
                        else { self.readProxy() }
                    }
                }
            }
        }
    }
}
