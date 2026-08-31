import Foundation
import AppKit
import Network
import IOKit.pwr_mgt
import LunaProto

/// Display presets. Stream size stays within 4096x2304 because the 2014
/// iMac's hardware can only H.264-decode up to ~4K; the receiver upscales
/// to its 5K panel, which matches how macOS scaled modes already work.
enum DisplayPreset: String, CaseIterable {
    case retina5KScaled
    case retina4K
    case plain1440

    var title: String {
        switch self {
        case .retina5KScaled: return "Retina 5K scaled — looks like 2560×1440 (best)"
        case .retina4K: return "Retina 4K — looks like 1920×1080 (bigger UI)"
        case .plain1440: return "2560×1440 — non-Retina (lowest bandwidth)"
        }
    }

    var displayPixels: (width: UInt32, height: UInt32) {
        switch self {
        case .retina5KScaled: return (5120, 2880)
        case .retina4K: return (3840, 2160)
        case .plain1440: return (2560, 1440)
        }
    }

    var hiDPI: Bool {
        switch self {
        case .retina5KScaled, .retina4K: return true
        case .plain1440: return false
        }
    }

    var streamSize: (width: Int, height: Int) {
        switch self {
        case .retina5KScaled, .retina4K: return (3840, 2160)
        case .plain1440: return (2560, 1440)
        }
    }

    var bitrate: Int {
        switch self {
        case .retina5KScaled, .retina4K: return 70_000_000
        case .plain1440: return 40_000_000
        }
    }
}

/// Orchestrates one streaming session: connection -> virtual display ->
/// capture/encode -> packets over the wire.
@available(macOS 12.3, *)
final class SessionController {
    enum State: Equatable {
        case idle
        case connecting(String)
        case streaming(String)
    }

    private let virtualDisplay = VirtualDisplaySession()
    private var connection: SenderConnection?
    private var resolver: ServiceResolver?
    private var encoder: CaptureEncoder?
    private var sleepAssertion: IOPMAssertionID = 0
    private let fps = 60

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((State) -> Void)?

    /// BSD name of the interface pinned in the menu; nil = automatic
    /// (wired first, then Wi-Fi).
    static var pinnedInterfaceName: String? {
        get {
            let name = UserDefaults.standard.string(forKey: "networkInterface") ?? ""
            return name.isEmpty ? nil : name
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: "networkInterface") }
    }

    /// "Thunderbolt Bridge (bridge0)" while connected, for the menu.
    private(set) var currentInterfaceLabel: String?
    /// Why the last connect attempt failed, shown in the menu while idle.
    private(set) var lastConnectError: String?

    /// Exposed for the --test-disconnect harness.
    var activeVirtualDisplayID: CGDirectDisplayID { virtualDisplay.displayID }

    // Roughly three stream-sized frames; beyond this the link is backed up
    // and we drop frames pre-encode so latency doesn't snowball.
    private var maxPendingBytes: Int {
        preset.bitrate / 8 / fps * 3
    }

    private var preset: DisplayPreset {
        DisplayPreset(rawValue: UserDefaults.standard.string(forKey: "preset") ?? "") ?? .retina5KScaled
    }

    func connect(endpoint: NWEndpoint, name: String) {
        disconnect()
        lastConnectError = nil
        state = .connecting(name)

        // NWConnection stalls when a Bonjour service endpoint meets
        // prohibitedInterfaceTypes, so for the wired-first probe we resolve
        // the service to host:port ourselves and dial the host directly.
        // The plain service connect stays as the fallback.
        guard case .service(let sname, let stype, let sdomain, _) = endpoint else {
            attemptConnection(endpoint: endpoint, fallback: endpoint, name: name, wiredOnly: true)
            return
        }
        let resolver = ServiceResolver { [weak self] result in
            guard let self, self.resolver != nil, case .connecting = self.state else { return }
            self.resolver = nil
            if let result, let port = NWEndpoint.Port(rawValue: result.port) {
                lunaLog("luna: resolved %@ -> %@:%d", sname, result.host, Int(result.port))
                self.attemptConnection(
                    endpoint: .hostPort(host: NWEndpoint.Host(result.host), port: port),
                    fallback: endpoint, name: name, wiredOnly: true
                )
            } else {
                lunaLog("luna: SRV resolve failed, connecting via service endpoint")
                self.attemptConnection(endpoint: endpoint, fallback: endpoint, name: name, wiredOnly: false)
            }
        }
        self.resolver = resolver
        resolver.resolve(name: sname, type: stype, domain: sdomain)
    }

    /// Probe the wired path (Thunderbolt bridge / Ethernet) first; if none
    /// exists within a couple of seconds, reconnect over any interface.
    private func attemptConnection(endpoint: NWEndpoint, fallback: NWEndpoint, name: String, wiredOnly: Bool) {
        // A pinned interface replaces the wired-first probe entirely; a pin
        // with no usable path right now falls back to automatic (logged).
        var pinnedInterface: NWInterface?
        if let pinName = Self.pinnedInterfaceName {
            if let iface = InterfaceMonitor.shared.interface(named: pinName) {
                pinnedInterface = iface
            } else {
                lunaLog("luna: pinned interface %@ has no usable path, connecting automatically", pinName)
            }
        }
        let conn: SenderConnection
        if let pinnedInterface {
            conn = SenderConnection(endpoint: endpoint, requiredInterface: pinnedInterface)
        } else {
            conn = SenderConnection(endpoint: endpoint, wiredOnly: wiredOnly)
        }
        connection = conn
        var didConnect = false  // both callbacks fire on the main queue
        conn.onReady = { [weak self, weak conn] in
            didConnect = true
            self?.currentInterfaceLabel = conn?.readyInterface.map(InterfaceMonitor.label(for:))
            lunaLog("luna: connected via %@ (%@ path)",
                    self?.currentInterfaceLabel ?? "unknown interface",
                    pinnedInterface != nil ? "pinned" : (wiredOnly ? "wired" : "default"))
            self?.onStateChange?(self?.state ?? .idle)  // refresh the menu's "via" line
            self?.handleConnected(name: name)
        }
        conn.onClosed = { [weak self, weak conn] reason in
            // Only react to the connection we currently own; a connection we
            // already replaced reporting closure must not kill the new one.
            guard let self, let conn, self.connection === conn else { return }
            if let reason { lunaLog("luna: connection closed: %@", reason) }
            if let pinnedInterface, !didConnect {
                // The user chose this interface; failing is better than
                // silently using another one.
                self.lastConnectError =
                    "Could not reach \(name) via \(InterfaceMonitor.label(for: pinnedInterface))"
                self.disconnect()
            } else if wiredOnly, pinnedInterface == nil, !didConnect {
                lunaLog("luna: no wired path to receiver, falling back to Wi-Fi")
                self.attemptConnection(endpoint: fallback, fallback: fallback, name: name, wiredOnly: false)
            } else {
                self.disconnect()
            }
        }
        conn.onMessage = { [weak self, weak conn] msg in
            guard let self, let conn, self.connection === conn else { return }
            if case .caps(let w, let h, let receiverName, _, _) = msg {
                lunaLog("luna: receiver %@ reports screen %dx%d", receiverName, w, h)
            }
        }
        conn.start()
    }

    private func handleConnected(name: String) {
        guard let connection else { return }
        let preset = preset
        let pixels = preset.displayPixels
        let stream = preset.streamSize

        connection.send(LunaWire.helloData(
            streamWidth: stream.width,
            streamHeight: stream.height,
            fps: fps,
            senderName: Host.current().localizedName ?? "Mac"
        ))

        guard virtualDisplay.create(
            pixelWidth: pixels.width,
            pixelHeight: pixels.height,
            hiDPI: preset.hiDPI,
            refreshHz: Double(fps),
            name: "Luna (\(name))"
        ) else {
            lunaLog("luna: virtual display creation failed")
            disconnect()
            return
        }

        // The new display takes a moment to appear in ScreenCaptureKit.
        startCapture(attempt: 0)
    }

    private func startCapture(attempt: Int) {
        guard let connection, virtualDisplay.isActive else { return }
        if attempt > 0 {
            lunaLog("luna: retrying capture start (attempt %d)", attempt)
        }
        let encoder = CaptureEncoder(config: .init(
            displayID: virtualDisplay.displayID,
            streamWidth: preset.streamSize.width,
            streamHeight: preset.streamSize.height,
            fps: fps,
            bitrate: preset.bitrate
        ))
        self.encoder = encoder
        encoder.onPacket = { [weak connection] packet in
            connection?.send(packet)
        }
        encoder.shouldDropFrame = { [weak self, weak connection] in
            guard let self, let connection else { return true }
            return connection.pendingBytes > self.maxPendingBytes
        }
        encoder.onError = { [weak self, weak encoder] message in
            DispatchQueue.main.async {
                // Ignore late errors from an encoder we already replaced.
                guard let self, let encoder, self.encoder === encoder else { return }
                if message.contains("not found"), attempt < 10 {
                    // Display not registered with SCK yet; retry shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.startCapture(attempt: attempt + 1)
                    }
                } else {
                    lunaLog("luna: %@", message)
                    self.disconnect()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.5 : 0)) { [weak self] in
            guard let self, self.encoder === encoder else { return }
            encoder.start()
            if case .connecting(let name) = self.state {
                self.state = .streaming(name)
            }
            self.preventSleep(true)
        }
    }

    func disconnect() {
        resolver = nil
        currentInterfaceLabel = nil
        encoder?.stop()
        encoder = nil
        connection?.cancel()
        connection = nil
        virtualDisplay.destroy()
        preventSleep(false)
        if state != .idle { state = .idle }
    }

    private func preventSleep(_ prevent: Bool) {
        if prevent, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Luna is streaming a display" as CFString,
                &sleepAssertion
            )
        } else if !prevent, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
