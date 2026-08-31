import Foundation
import Network
import dnssd
import LunaProto

/// Resolves a Bonjour service to its hostname + port (SRV record).
/// Needed because NWConnection stalls when a service endpoint is combined
/// with prohibitedInterfaceTypes, while a plain host:port dial honors the
/// prohibition and happily uses a Thunderbolt bridge / Ethernet link.
final class ServiceResolver {
    private let queue = DispatchQueue(label: "luna.resolver")
    private var ref: DNSServiceRef?
    private let completion: ((host: String, port: UInt16)?) -> Void
    private var finished = false

    /// completion fires exactly once, on the main queue; nil on failure.
    init(completion: @escaping ((host: String, port: UInt16)?) -> Void) {
        self.completion = completion
    }

    func resolve(name: String, type: String, domain: String, timeout: TimeInterval = 2.0) {
        let context = Unmanaged.passRetained(self).toOpaque()
        var r: DNSServiceRef?
        let err = DNSServiceResolve(
            &r, 0, 0, name, type, domain,
            { _, _, _, errorCode, _, hosttarget, portNBO, _, _, context in
                guard let context else { return }
                let me = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
                if errorCode == kDNSServiceErr_NoError, let hosttarget {
                    me.finish((String(cString: hosttarget), UInt16(bigEndian: portNBO)))
                } else {
                    me.finish(nil)
                }
            },
            context
        )
        guard err == kDNSServiceErr_NoError, let r else {
            Unmanaged<ServiceResolver>.fromOpaque(context).release()
            DispatchQueue.main.async { self.completion(nil) }
            return
        }
        ref = r
        DNSServiceSetDispatchQueue(r, queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ result: (host: String, port: UInt16)?) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            if let ref = self.ref {
                DNSServiceRefDeallocate(ref)
                self.ref = nil
            }
            DispatchQueue.main.async { self.completion(result) }
            Unmanaged.passUnretained(self).release()  // balances passRetained
        }
    }
}

/// Browses Bonjour for LunaReceiver instances on the local network.
final class ReceiverBrowser {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "luna.browser")

    /// Called on the main queue whenever the result set changes.
    var onResults: (([NWBrowser.Result]) -> Void)?

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: LunaWire.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let sorted = results.sorted { a, b in
                Self.name(of: a) < Self.name(of: b)
            }
            DispatchQueue.main.async { self?.onResults?(sorted) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                lunaLog("luna: bonjour browse failed: %@", error.localizedDescription)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    static func name(of result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint {
            return name
        }
        return "\(result.endpoint)"
    }
}

/// One outbound TCP connection to a receiver, with send backpressure tracking.
final class SenderConnection {
    private let queue = DispatchQueue(label: "luna.sender.net")
    private let connection: NWConnection
    private let parser = LunaMessageParser()
    private let pendingLock = NSLock()
    private var pending = 0

    /// Bytes handed to the connection but not yet processed by the transport.
    var pendingBytes: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending
    }

    var onReady: (() -> Void)?          // main queue
    var onClosed: ((String?) -> Void)?  // main queue
    var onMessage: ((LunaMessage) -> Void)?  // main queue

    private var closed = false
    private let wiredOnly: Bool
    private let pinned: Bool
    private var becameReady = false  // touched only on `queue`
    /// Interface of the path the connection became ready on. Written on
    /// `queue` just before onReady is dispatched, read on the main queue.
    private(set) var readyInterface: NWInterface?

    /// wiredOnly: refuse Wi-Fi paths and give up quickly, so the caller can
    /// probe for a Thunderbolt bridge / Ethernet link before falling back.
    /// requiredInterface: pin the connection to that interface (no fallback).
    init(endpoint: NWEndpoint, wiredOnly: Bool = false, requiredInterface: NWInterface? = nil) {
        self.wiredOnly = wiredOnly
        self.pinned = requiredInterface != nil
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        if wiredOnly {
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
        }
        if let requiredInterface {
            params.requiredInterface = requiredInterface
        }
        connection = NWConnection(to: endpoint, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.becameReady = true
                self.readyInterface = self.connection.currentPath?.availableInterfaces.first
                DispatchQueue.main.async { self.onReady?() }
            case .waiting(let error):
                // Normal connects ride out .waiting; the wired probe and a
                // pinned interface treat "no usable path" as an immediate miss.
                if self.wiredOnly || self.pinned {
                    self.close(reason: "no usable path (\(error.localizedDescription))")
                    self.connection.cancel()
                }
            case .failed(let error):
                self.close(reason: error.localizedDescription)
            case .cancelled:
                self.close(reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop()
        let probeTimeout: TimeInterval? = wiredOnly ? 2.5 : (pinned ? 5.0 : nil)
        if let probeTimeout {
            queue.asyncAfter(deadline: .now() + probeTimeout) { [weak self] in
                guard let self, !self.becameReady else { return }
                self.close(reason: self.wiredOnly
                    ? "wired probe timed out" : "connect timed out on the pinned interface")
                self.connection.cancel()
            }
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for msg in self.parser.feed(data) {
                    DispatchQueue.main.async { self.onMessage?(msg) }
                }
                if self.parser.corrupted {
                    self.close(reason: "stream out of sync (oversized frame)")
                    return
                }
            }
            if isComplete || error != nil {
                self.close(reason: error?.localizedDescription ?? "receiver disconnected")
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) {
        pendingLock.lock()
        pending += data.count
        pendingLock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.pendingLock.lock()
            self.pending -= data.count
            self.pendingLock.unlock()
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func close(reason: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.onClosed?(reason)
        }
    }
}
