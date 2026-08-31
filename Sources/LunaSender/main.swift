import AppKit
import CoreGraphics
import CVD

// --selftest: try virtual display configurations, print what the system
// actually registered for each, then tear down. Verifies the private API
// works on this macOS without needing screen-recording permission.
if CommandLine.arguments.contains("--selftest") {
    func report(_ vd: VirtualDisplaySession) {
        let id = vd.displayID
        let bounds = CGDisplayBounds(id)
        print("  bounds=\(Int(bounds.width))x\(Int(bounds.height)) points")
        if let mode = CGDisplayCopyDisplayMode(id) {
            print("  current: \(mode.width)x\(mode.height) points, \(mode.pixelWidth)x\(mode.pixelHeight) pixels, \(mode.refreshRate) Hz")
        }
        for m in VirtualDisplaySession.allModes(id) where m.pixelWidth >= 1920 {
            let tag = m.pixelWidth != m.width ? "  <-- HiDPI" : ""
            print("  mode: \(m.width)x\(m.height) points, \(m.pixelWidth)x\(m.pixelHeight) pixels\(tag)")
        }
    }

    struct Attempt {
        let label: String
        let hiDPIValue: UInt32
        let modes: [(UInt32, UInt32)]
    }
    let attempts = [
        Attempt(label: "hiDPI=1, mode in points (2560x1440)", hiDPIValue: 1, modes: [(2560, 1440)]),
        Attempt(label: "hiDPI=2, mode in points (2560x1440)", hiDPIValue: 2, modes: [(2560, 1440)]),
        Attempt(label: "hiDPI=1, modes points+pixels", hiDPIValue: 1, modes: [(2560, 1440), (5120, 2880)]),
        Attempt(label: "hiDPI=2, mode in pixels (5120x2880)", hiDPIValue: 2, modes: [(5120, 2880)]),
    ]

    let vd = VirtualDisplaySession()
    for attempt in attempts {
        print("SELFTEST \(attempt.label)")
        guard vd.create(
            maxPixels: (5120, 2880),
            hiDPIValue: attempt.hiDPIValue,
            modes: attempt.modes,
            targetPointWidth: 2560,
            targetPixelWidth: 5120,
            refreshHz: 60,
            name: "Luna Selftest"
        ) else {
            print("  FAILED to create")
            continue
        }
        Thread.sleep(forTimeInterval: 1.5)
        report(vd)
        vd.destroy()
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("SELFTEST done")
    exit(0)
}

let app = NSApplication.shared
if #available(macOS 13.0, *) {
    let delegate = SenderAppDelegate()
    app.delegate = delegate
    app.run()
} else {
    fputs("LunaSender requires macOS 13 or newer.\n", stderr)
    exit(1)
}
