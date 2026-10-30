import Foundation
import AppKit
import CoreMedia
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

    /// Default "looks like" size in points.
    var defaultMode: (UInt32, UInt32) {
        switch self {
        case .retina5KScaled, .plain1440: return (2560, 1440)
        case .retina4K: return (1920, 1080)
        }
    }

    /// Sizes offered in System Settings, all 16:9. The Retina presets match
    /// a real 5K iMac's scaled list plus 1920x1080.
    var modes: [(UInt32, UInt32)] {
        switch self {
        case .retina5KScaled, .retina4K:
            return [(3200, 1800), (2880, 1620), (2560, 1440), (2304, 1296), (2048, 1152), (1920, 1080)]
        case .plain1440:
            return [(2560, 1440), (1920, 1080)]
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
    private var cursorTracker: CursorTracker?
    /// The receiver said (in caps) it draws the cursor from cursorPos messages.
    private var receiverDrawsCursor = false
    /// Frames handed to the encoder and not yet acked by the receiver
    /// (timestamp -> host time submitted). Touched from the capture queue and main.
    private let flightLock = NSLock()
    private var inFlight: [Int64: Double] = [:]
    private var acksSeen = false
    private var stats = StreamStats()
    private var statsTimer: Timer?
    /// When the oldest unacked frame is this old, frames are queuing somewhere
    /// (network, receiver), so the next capture is skipped instead. A frame
    /// count would not do: a healthy round trip already spans 3-4 frames at
    /// 60 fps, and a cap of 3 skipped frames all the time.
    private static let maxFrameAge = 0.1

    /// The receiver said (in caps) it hardware-decodes HEVC.
    private var receiverDecodesHEVC = false

    /// HEVC carries the full 5K frame. H.264 stays at 4K, the most the
    /// iMacs' H.264 decoders take.
    /// 5K goes out as four 1280x2880 strips; only changed ones are encoded.
    private static let hevcStrips = 4
    private var useHEVC: Bool { receiverDecodesHEVC && preset == .retina5KScaled }
    private var streamSize: (width: Int, height: Int) { useHEVC ? (5120, 2880) : preset.streamSize }
    private var bitrate: Int {
        if let override = Int(ProcessInfo.processInfo.environment["LUNA_BITRATE"] ?? ""), override > 0 { return override }
        return useHEVC ? 120_000_000 : preset.bitrate
    }
    private var sleepAssertion: IOPMAssertionID = 0
    private var latencyActivity: NSObjectProtocol?
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

    // A quarter second of stream; beyond this the link is backed up and we
    // drop frames pre-encode so latency doesn't snowball. Three frames' worth
    // was crossed by single bursts (several strips' keyframes at once) and
    // skipped frames even over Thunderbolt; acks catch real backlog sooner.
    private var maxPendingBytes: Int {
        bitrate / 8 / 4
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
            // Normally the receiver's caps start the stream; one that never
            // sends caps (e.g. `nc` in the test harness) gets H.264 after 1 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, let conn, self.connection === conn else { return }
                self.handleConnected(name: name)
            }
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
        conn.onFrameAck = { [weak self] pts, receiverMicros in self?.frameAcked(pts, receiverMicros: receiverMicros) }
        conn.onMessage = { [weak self, weak conn] msg in
            guard let self, let conn, self.connection === conn else { return }
            if case .caps(let w, let h, let receiverName, _, _, let drawsCursor, let decodesHEVC) = msg {
                lunaLog("luna: receiver %@ reports screen %dx%d, HEVC decode %@",
                        receiverName, w, h, decodesHEVC ? "yes" : "no")
                if !self.virtualDisplay.isActive {
                    self.receiverDecodesHEVC = decodesHEVC
                }
                if drawsCursor {
                    self.receiverDrawsCursor = true
                    self.encoder?.hideCursor()
                    self.startCursorTracking()
                }
                self.handleConnected(name: name)
            }
        }
        conn.start()
    }

    /// Runs once per connection, on caps or the caps timeout.
    private func handleConnected(name: String) {
        guard let connection, !virtualDisplay.isActive else { return }
        let preset = preset
        let stream = streamSize
        lunaLog("luna: streaming %dx%d %@", stream.width, stream.height, useHEVC ? "HEVC" : "H.264")

        connection.send(LunaWire.helloData(
            streamWidth: stream.width,
            streamHeight: stream.height,
            fps: fps,
            senderName: Host.current().localizedName ?? "Mac",
            tiles: useHEVC ? Self.hevcStrips : 1
        ))

        guard virtualDisplay.create(
            modes: preset.modes,
            defaultMode: preset.defaultMode,
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
            streamWidth: streamSize.width,
            streamHeight: streamSize.height,
            fps: fps,
            bitrate: bitrate,
            showsCursor: !receiverDrawsCursor,
            hevc: useHEVC,
            tiles: Self.hevcStrips
        ))
        self.encoder = encoder
        encoder.onPacket = { [weak self, weak connection] packet in
            connection?.send(packet)
            guard let self else { return }
            self.flightLock.lock()
            self.stats.bytes += packet.count
            self.flightLock.unlock()
        }
        encoder.onStripCopied = { [weak self] seconds in
            guard let self else { return }
            self.flightLock.lock()
            self.stats.copyTimes.append(seconds)
            self.flightLock.unlock()
        }
        encoder.onChangeCaptured = { [weak self] seconds in
            guard let self else { return }
            self.flightLock.lock()
            self.stats.changeToCapture.append(seconds)
            self.flightLock.unlock()
        }
        encoder.onFrameEncoded = { [weak self] seconds in
            guard let self else { return }
            self.flightLock.lock()
            self.stats.encodeTimes.append(seconds)
            self.flightLock.unlock()
        }
        encoder.shouldDropFrame = { [weak self, weak connection] in
            guard let self, let connection else { return true }
            if connection.pendingBytes > self.maxPendingBytes {
                self.flightLock.lock()
                self.stats.droppedNetwork += 1
                self.flightLock.unlock()
                return true
            }
            return self.tooManyInFlight()
        }
        encoder.onFrameSubmitted = { [weak self] pts in self?.frameSubmitted(pts) }
        encoder.onFrameSkipped = { [weak self] in
            guard let self else { return }
            self.flightLock.lock()
            self.stats.droppedEncoderBusy += 1
            self.flightLock.unlock()
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
            self.startCursorTracking()
            self.statsTimer?.invalidate()
            self.statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.logStats()
            }
        }
    }

    private static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// Capture queue.
    private func tooManyInFlight() -> Bool {
        flightLock.lock()
        defer { flightLock.unlock() }
        guard acksSeen else { return false }  // older receivers never ack
        // A frame unacked for half a second is lost (e.g. a decoder flush);
        // forget it so the stream can't stall waiting for it.
        let cutoff = Self.hostNow() - 0.5
        inFlight = inFlight.filter { $0.value > cutoff }
        if let oldest = inFlight.values.min(), Self.hostNow() - oldest > Self.maxFrameAge {
            stats.droppedBacklog += 1
            return true
        }
        return false
    }

    /// Capture queue.
    private func frameSubmitted(_ pts: Int64) {
        let now = Self.hostNow()
        flightLock.lock()
        inFlight[pts] = now
        stats.submitted += 1
        stats.captureDelays.append(now - Double(pts) / 1_000_000)
        flightLock.unlock()
    }

    /// Network queue.
    private func frameAcked(_ pts: Int64, receiverMicros: Int) {
        let now = Self.hostNow()
        flightLock.lock()
        acksSeen = true
        // pts is the capture time on the host clock: this is capture -> decoded on the iMac.
        stats.latencies.append(now - Double(pts) / 1_000_000)
        stats.receiverTimes.append(Double(receiverMicros) / 1_000_000)
        inFlight = inFlight.filter { $0.key > pts }
        flightLock.unlock()
    }

    private func logStats() {
        flightLock.lock()
        let s = stats
        stats = StreamStats()
        flightLock.unlock()
        lunaLog("luna: last 5 s: %d frames sent, %d skipped (network), %d skipped (receiver behind), "
                + "%d skipped (encoder busy), %.0f Mbit/s; capture->encoder %@, copy %@, encode %@, "
                + "receiver arrival->decoded %@, capture->decoded on receiver %@",
                s.submitted, s.droppedNetwork, s.droppedBacklog, s.droppedEncoderBusy,
                Double(s.bytes) * 8 / 5 / 1_000_000,
                StreamStats.describe(s.captureDelays), StreamStats.describe(s.copyTimes),
                StreamStats.describe(s.encodeTimes),
                StreamStats.describe(s.receiverTimes), StreamStats.describe(s.latencies))
        if !s.changeToCapture.isEmpty {
            lunaLog("luna-test: change->capture %@", StreamStats.describe(s.changeToCapture))
        }
    }

    /// Needs both the virtual display and the receiver's caps; called when
    /// either arrives, starts once.
    private func startCursorTracking() {
        guard receiverDrawsCursor, cursorTracker == nil, virtualDisplay.isActive, let connection else { return }
        let tracker = CursorTracker(displayID: virtualDisplay.displayID) { [weak connection] in
            connection?.send($0)
        }
        tracker.start()
        cursorTracker = tracker
    }

    func disconnect() {
        resolver = nil
        currentInterfaceLabel = nil
        cursorTracker?.stop()
        cursorTracker = nil
        receiverDrawsCursor = false
        receiverDecodesHEVC = false
        statsTimer?.invalidate()
        statsTimer = nil
        flightLock.lock()
        inFlight = [:]
        acksSeen = false
        stats = StreamStats()
        flightLock.unlock()
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
        // The sleep assertion doesn't stop App Nap or timer coalescing, which
        // slow every frame of a background (menu bar) app.
        if prevent, latencyActivity == nil {
            latencyActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Luna is streaming a display")
        } else if !prevent, let activity = latencyActivity {
            ProcessInfo.processInfo.endActivity(activity)
            latencyActivity = nil
        }
    }
}

/// Counters for the periodic stream log line.
struct StreamStats {
    var submitted = 0
    var droppedNetwork = 0
    var droppedBacklog = 0
    var droppedEncoderBusy = 0
    var captureDelays: [Double] = []
    var latencies: [Double] = []
    var encodeTimes: [Double] = []
    var copyTimes: [Double] = []
    var changeToCapture: [Double] = []
    var receiverTimes: [Double] = []
    var bytes = 0

    static func describe(_ seconds: [Double]) -> String {
        guard !seconds.isEmpty else { return "n/a" }
        let ms = seconds.map { $0 * 1000 }.sorted()
        return String(format: "median %.0f ms, p90 %.0f ms, max %.0f ms", ms[ms.count / 2], ms[ms.count * 9 / 10], ms.last!)
    }
}
