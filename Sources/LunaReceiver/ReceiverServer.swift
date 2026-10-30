import Foundation
import CoreGraphics
import Network
import VideoToolbox
import LunaProto

/// Advertises this Mac via Bonjour and accepts one sender connection.
final class ReceiverServer {
    private let queue = DispatchQueue(label: "luna.receiver.net")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = LunaMessageParser()
    private let pendingLock = NSLock()
    private var pending = 0

    /// Bytes handed to the connection but not yet processed by the transport
    /// — the reverse channel's backpressure signal (camera frames are skipped
    /// while this is high, so a slow link raises the frame rate, not latency).
    var pendingBytes: Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending
    }

    // All callbacks fire on the main queue.
    var onListening: ((String) -> Void)?
    var onMessage: ((LunaMessage) -> Void)?
    var onDisconnected: (() -> Void)?

    /// "Thunderbolt Bridge (bridge0)" — the link the sender's connection
    /// arrived on. Written on the network queue when the connection becomes
    /// ready, read from the main queue afterwards (the sender's hello always
    /// arrives later).
    private(set) var connectionInterfaceLabel: String?

    /// Fixed port so the receiver's address survives relaunches; falls back
    /// to an ephemeral port if something else already holds it.
    static let preferredPort: UInt16 = 52525

    func start() {
        start(fixedPort: Self.preferredPort)
    }

    private func start(fixedPort: UInt16?) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)

        let listener: NWListener
        do {
            if let fixedPort, let port = NWEndpoint.Port(rawValue: fixedPort) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            if fixedPort != nil {
                lunaLog("luna: port %d unavailable (%@), using an ephemeral port",
                      Int(fixedPort!), error.localizedDescription)
                start(fixedPort: nil)
            } else {
                lunaLog("luna: could not create listener: %@", error.localizedDescription)
            }
            return
        }
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Mac",
            type: LunaWire.serviceType
        )
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                let port = listener.port.map { String($0.rawValue) } ?? "?"
                let host = ProcessInfo.processInfo.hostName
                DispatchQueue.main.async {
                    self?.onListening?("\(host):\(port)")
                }
            }
            if case .failed(let error) = state {
                lunaLog("luna: listener failed: %@", error.localizedDescription)
                if fixedPort != nil {
                    // The fixed port bind can also fail here rather than at
                    // creation; retry once on an ephemeral port.
                    DispatchQueue.main.async { [weak self] in
                        self?.listener?.cancel()
                        self?.listener = nil
                        self?.start(fixedPort: nil)
                    }
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ conn: NWConnection) {
        guard connection == nil else {
            conn.cancel()
            return
        }
        connection = conn
        parser = LunaMessageParser()

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let iface = conn.currentPath?.availableInterfaces.first {
                    let label = NetInfo.label(bsd: iface.name, type: iface.type)
                    self?.connectionInterfaceLabel = label
                    lunaLog("luna: sender connected via %@", label)
                }
                let screen = ReceiverScreenInfo.current()
                conn.send(
                    content: LunaWire.capsData(
                        screenWidth: screen.width,
                        screenHeight: screen.height,
                        name: Host.current().localizedName ?? "Mac",
                        // This build has no reverse camera/mic channel.
                        hasCamera: false,
                        hasMic: false,
                        drawsCursor: true,
                        decodesHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
                    ),
                    completion: .contentProcessed { _ in }
                )
            case .failed, .cancelled:
                self?.dropConnection()
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                let messages = self.parser.feed(data)
                if !messages.isEmpty {
                    DispatchQueue.main.async {
                        for msg in messages { self.onMessage?(msg) }
                    }
                }
                if self.parser.corrupted {
                    lunaLog("luna: stream out of sync (oversized frame), dropping the sender")
                    self.parser = LunaMessageParser()
                    self.dropConnection()
                    return
                }
            }
            if isComplete || error != nil {
                self.dropConnection()
                return
            }
            self.receiveLoop(conn)
        }
    }

    /// Sends a packet to the connected sender; dropped when nobody is connected.
    /// Safe to call from any thread.
    func send(_ data: Data) {
        pendingLock.lock()
        pending += data.count
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            guard let conn = self.connection else {
                self.settle(data.count)
                return
            }
            conn.send(content: data, completion: .contentProcessed { [weak self] _ in self?.settle(data.count) })
        }
    }

    private func settle(_ bytes: Int) {
        pendingLock.lock()
        pending -= bytes
        pendingLock.unlock()
    }

    private func dropConnection() {
        queue.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            conn.cancel()
            self.connection = nil
            self.connectionInterfaceLabel = nil
            DispatchQueue.main.async { self.onDisconnected?() }
        }
    }
}

enum ReceiverScreenInfo {
    static func current() -> (width: Int, height: Int) {
        let id = CGMainDisplayID()
        return (Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)))
    }
}
