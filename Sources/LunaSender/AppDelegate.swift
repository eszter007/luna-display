import AppKit
import Network
import LunaProto

@available(macOS 12.3, *)
final class SenderAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let browser = ReceiverBrowser()
    private let session = SessionController()
    private var results: [NWBrowser.Result] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "☾"
        statusItem.button?.toolTip = "Luna Sender"

        session.onStateChange = { [weak self] state in
            switch state {
            case .idle: self?.statusItem.button?.title = "☾"
            case .connecting: self?.statusItem.button?.title = "☾…"
            case .streaming: self?.statusItem.button?.title = "☾●"
            }
            self?.rebuildMenu()
        }

        browser.onResults = { [weak self] results in
            self?.results = results
            self?.rebuildMenu()
        }
        browser.start()
        InterfaceMonitor.shared.onChange = { [weak self] in self?.rebuildMenu() }
        InterfaceMonitor.shared.start()
        rebuildMenu()
        startDisconnectTestIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.disconnect()
        browser.stop()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // With autoenable on (the default), AppKit ignores isEnabled on
        // targeted items, so Disconnect could never be greyed out.
        menu.autoenablesItems = false

        let stateTitle: String
        switch session.state {
        case .idle: stateTitle = "Not connected"
        case .connecting(let name): stateTitle = "Connecting to \(name)…"
        case .streaming(let name): stateTitle = "Streaming to \(name)"
        }
        menu.addItem(withTitle: stateTitle, action: nil, keyEquivalent: "").isEnabled = false
        if session.state != .idle, let via = session.currentInterfaceLabel {
            let item = NSMenuItem(title: "via \(via)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }
        if session.state == .idle, let error = session.lastConnectError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Receivers on network", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if results.isEmpty {
            let none = NSMenuItem(title: "None found yet…", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)
        } else {
            for (index, result) in results.enumerated() {
                let item = NSMenuItem(
                    title: ReceiverBrowser.name(of: result),
                    action: #selector(connectToResult(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        let manual = NSMenuItem(title: "Connect to Address…", action: #selector(connectToAddress), keyEquivalent: "")
        manual.target = self
        menu.addItem(manual)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "preset") ?? DisplayPreset.retina5KScaled.rawValue
        for preset in DisplayPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = preset.rawValue == current ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        menu.addItem(modeItem)
        menu.setSubmenu(modeMenu, for: modeItem)

        let netMenu = NSMenu()
        let pinnedName = SessionController.pinnedInterfaceName
        let auto = NSMenuItem(
            title: "Automatic — wired first, then Wi-Fi",
            action: #selector(selectInterface(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = pinnedName == nil ? .on : .off
        netMenu.addItem(auto)
        let interfaces = InterfaceMonitor.shared.interfaces
        if !interfaces.isEmpty { netMenu.addItem(.separator()) }
        for iface in interfaces {
            let item = NSMenuItem(
                title: InterfaceMonitor.label(for: iface),
                action: #selector(selectInterface(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = iface.name
            item.state = iface.name == pinnedName ? .on : .off
            netMenu.addItem(item)
        }
        // A pinned interface that currently has no path stays visible, so
        // the checkmark never silently disappears.
        if let pinnedName, InterfaceMonitor.shared.interface(named: pinnedName) == nil {
            let gone = NSMenuItem(
                title: "\(pinnedName) — no usable path",
                action: #selector(selectInterface(_:)), keyEquivalent: "")
            gone.target = self
            gone.representedObject = pinnedName
            gone.state = .on
            netMenu.addItem(gone)
        }
        let netItem = NSMenuItem(title: "Network Interface", action: nil, keyEquivalent: "")
        menu.addItem(netItem)
        menu.setSubmenu(netMenu, for: netItem)

        menu.addItem(.separator())

        let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
        disconnect.target = self
        disconnect.isEnabled = session.state != .idle
        menu.addItem(disconnect)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Luna Sender", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func connectToResult(_ sender: NSMenuItem) {
        guard results.indices.contains(sender.tag) else { return }
        let result = results[sender.tag]
        session.connect(endpoint: result.endpoint, name: ReceiverBrowser.name(of: result))
    }

    @objc private func connectToAddress() {
        let alert = NSAlert()
        alert.messageText = "Connect to Receiver"
        alert.informativeText = "Enter the address shown on the receiver's waiting screen (host:port)."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "imac.local:52525"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let parts = field.stringValue.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else { return }
        let host = NWEndpoint.Host(String(parts[0]))
        session.connect(endpoint: .hostPort(host: host, port: port), name: field.stringValue)
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "preset")
        rebuildMenu()
    }

    @objc private func selectInterface(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let newPin = raw.isEmpty ? nil : raw
        guard newPin != SessionController.pinnedInterfaceName else { return }
        SessionController.pinnedInterfaceName = newPin
        rebuildMenu()
        reconnectForInterfaceChange()
    }

    /// A live session keeps its old path, so redial the same receiver to
    /// make the new choice take effect immediately.
    private func reconnectForInterfaceChange() {
        let name: String
        switch session.state {
        case .idle: return
        case .connecting(let n), .streaming(let n): name = n
        }
        if let result = results.first(where: { ReceiverBrowser.name(of: $0) == name }) {
            session.connect(endpoint: result.endpoint, name: name)
            return
        }
        let parts = name.split(separator: ":")
        if parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) {
            session.connect(
                endpoint: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port), name: name)
        }
        // Otherwise the choice applies on the next connect.
    }

    @objc private func disconnect() {
        session.disconnect()
    }
}

// MARK: - Dev harness
// `--test-disconnect host:port` connects to a receiver, streams briefly,
// then invokes the same disconnect action as the menu item and verifies
// full teardown (state idle, virtual display gone). Exits 0 on PASS.
@available(macOS 12.3, *)
extension SenderAppDelegate {
    private var testLogURL: URL? {
        guard let idx = CommandLine.arguments.firstIndex(of: "--test-log"),
              CommandLine.arguments.indices.contains(idx + 1) else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    }

    private func testLog(_ message: String) {
        lunaLog("luna-test: %@", message)
        guard let url = testLogURL, let data = "luna-test: \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func startDisconnectTestIfRequested() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--test-disconnect"),
              CommandLine.arguments.indices.contains(idx + 1) else { return }
        let address = CommandLine.arguments[idx + 1]
        let parts = address.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else {
            testLog("bad address \(address)")
            exit(2)
        }
        let existing = session.onStateChange
        session.onStateChange = { [weak self] state in
            existing?(state)
            self?.testLog("state -> \(state)")
        }
        testLog("connecting to \(address)")
        session.connect(
            endpoint: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port),
            name: "test"
        )
        pollForStreaming(deadline: Date().addingTimeInterval(30))
    }

    private func pollForStreaming(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if case .streaming = session.state {
                let displayID = session.activeVirtualDisplayID
                let seconds = Double(ProcessInfo.processInfo.environment["LUNA_TEST_SECONDS"] ?? "") ?? 4
                testLog("streaming on display \(displayID), disconnecting in \(Int(seconds))s")
                // LUNA_TEST_ANIMATE=1: a window moving across the virtual
                // display at 60 fps, like a drag, so the stats see real load.
                let animation = ProcessInfo.processInfo.environment["LUNA_TEST_ANIMATE"] != nil
                    ? Self.startTestAnimation(on: displayID) : nil
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
                    animation?.invalidate()
                    disconnect()  // the same action the menu item fires
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                        verifyTeardown(displayID: displayID)
                    }
                }
            } else if Date() < deadline {
                pollForStreaming(deadline: deadline)
            } else {
                testLog("FAIL — never reached streaming (screen-recording permission missing?)")
                exit(1)
            }
        }
    }

    private static func startTestAnimation(on displayID: CGDirectDisplayID) -> Timer? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) else { return nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .systemTeal
        window.orderFrontRegardless()
        var step = 0.0
        return Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            step += 1
            let frame = screen.frame
            let x = frame.minX + (frame.width - 900) * (0.5 + 0.5 * sin(step / 40))
            let y = frame.minY + (frame.height - 600) * (0.5 + 0.5 * cos(step / 55))
            window.setFrameOrigin(NSPoint(x: x, y: y))
            if !timer.isValid { window.close() }
        }
    }

    private func verifyTeardown(displayID: CGDirectDisplayID) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let displayGone = !ids.prefix(Int(count)).contains(displayID)
        let idle = session.state == .idle
        if displayGone && idle {
            testLog("PASS — state idle, virtual display \(displayID) removed")
            exit(0)
        }
        testLog("FAIL — idle=\(idle) displayGone=\(displayGone)")
        exit(1)
    }
}
