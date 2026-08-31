import Foundation
import LunaProto
import CoreGraphics
import CVD

/// Owns one virtual display. Releasing the CGVirtualDisplay tears it down.
final class VirtualDisplaySession {
    private var display: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = 0

    var isActive: Bool { display != nil }

    /// pixelWidth/pixelHeight are physical pixels. With hiDPI the desktop
    /// "looks like" half that in each dimension (Retina).
    func create(pixelWidth: UInt32, pixelHeight: UInt32, hiDPI: Bool, refreshHz: Double, name: String) -> Bool {
        let modeWidth = hiDPI ? pixelWidth / 2 : pixelWidth
        let modeHeight = hiDPI ? pixelHeight / 2 : pixelHeight
        return create(
            maxPixels: (pixelWidth, pixelHeight),
            hiDPIValue: hiDPI ? 1 : 0,
            modes: [(modeWidth, modeHeight)],
            targetPointWidth: Int(modeWidth),
            targetPixelWidth: Int(pixelWidth),
            refreshHz: refreshHz,
            name: name
        )
    }

    func create(
        maxPixels: (UInt32, UInt32),
        hiDPIValue: UInt32,
        modes modesInPoints: [(UInt32, UInt32)],
        targetPointWidth: Int,
        targetPixelWidth: Int,
        refreshHz: Double,
        name: String
    ) -> Bool {
        destroy()
        let pixelWidth = maxPixels.0
        let pixelHeight = maxPixels.1

        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = name
        desc.maxPixelsWide = pixelWidth
        desc.maxPixelsHigh = pixelHeight
        // Physical dimensions of a 27" iMac panel so scaling/DPI math is sane.
        desc.sizeInMillimeters = CGSize(width: 596, height: 335)
        // WindowServer refuses a duplicate EDID identity, so a second sender
        // on the same Mac (e.g. the --test-disconnect harness next to a live
        // session) must give its display a serial of its own.
        desc.serialNum = ProcessInfo.processInfo.environment["LUNA_VD_SERIAL"]
            .flatMap(UInt32.init) ?? 0x0001
        desc.productID = 0x5C4E
        desc.vendorID = 0x4C58
        desc.redPrimary = CGPoint(x: 0.640, y: 0.330)
        desc.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        desc.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        desc.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        desc.terminationHandler = { _, _ in
            lunaLog("luna: virtual display terminated by the system")
        }

        guard let d = CGVirtualDisplay(descriptor: desc) else {
            lunaLog("luna: CGVirtualDisplay init failed")
            return false
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPIValue
        settings.modes = modesInPoints.map {
            CGVirtualDisplayMode(width: $0.0, height: $0.1, refreshRate: refreshHz)
        }
        guard d.apply(settings) else {
            lunaLog("luna: applySettings failed for virtual display")
            return false
        }

        display = d
        displayID = d.displayID
        selectMode(pointWidth: targetPointWidth, pixelWidth: targetPixelWidth)
        lunaLog("luna: virtual display created, id=%u %ux%u hiDPI=%u", displayID, pixelWidth, pixelHeight, hiDPIValue)
        return true
    }

    static func allModes(_ displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
    }

    /// The system picks its own default mode; switch to the one we asked for.
    private func selectMode(pointWidth: Int, pixelWidth: Int) {
        let modes = Self.allModes(displayID)
        guard !modes.isEmpty else { return }
        let target = modes.first { $0.width == pointWidth && $0.pixelWidth == pixelWidth }
            ?? modes.max { $0.pixelWidth < $1.pixelWidth }
        guard let target, target.pixelWidth != CGDisplayCopyDisplayMode(displayID)?.pixelWidth
            || target.width != CGDisplayCopyDisplayMode(displayID)?.width
        else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        if CGCompleteDisplayConfiguration(config, .permanently) != .success {
            lunaLog("luna: could not switch virtual display mode")
        }
    }

    func destroy() {
        display = nil
        displayID = 0
    }
}
