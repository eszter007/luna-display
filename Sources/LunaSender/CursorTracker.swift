import AppKit
import LunaProto

/// Streams the cursor position and shape to a receiver that draws the cursor
/// itself, so pointer movement skips the capture/encode/decode delay.
final class CursorTracker {
    private let displayID: CGDirectDisplayID
    private let send: (Data) -> Void
    private var monitor: Any?
    private var shapeTimer: Timer?
    private var lastShape: Data?
    private var onDisplay = false

    init(displayID: CGDirectDisplayID, send: @escaping (Data) -> Void) {
        self.displayID = displayID
        self.send = send
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in self?.sendPosition() }
        // ponytail: NSCursor has no change notification, so the shape is polled
        // at 20 Hz; a shape change can lag the move by up to 50 ms.
        shapeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.sendShape()
        }
        sendPosition()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        shapeTimer?.invalidate()
        shapeTimer = nil
    }

    private func sendPosition() {
        guard let location = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(displayID)
        let visible = bounds.contains(location)
        // One "hidden" message when the pointer leaves, then stay quiet.
        guard visible || onDisplay else { return }
        if visible, !onDisplay { lastShape = nil }  // resend the shape on entry
        onDisplay = visible
        send(LunaWire.cursorPosData(
            x: Float((location.x - bounds.minX) / bounds.width),
            y: Float((location.y - bounds.minY) / bounds.height),
            visible: visible
        ))
        if lastShape == nil { sendShape() }
    }

    private func sendShape() {
        guard onDisplay, let cursor = NSCursor.currentSystem,
              let cgImage = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]), png != lastShape else { return }
        lastShape = png
        let size = cursor.image.size
        let bounds = CGDisplayBounds(displayID)
        send(LunaWire.cursorImageData(
            hotX: Float(cursor.hotSpot.x / size.width),
            hotY: Float(cursor.hotSpot.y / size.height),
            width: Float(size.width / bounds.width),
            height: Float(size.height / bounds.height),
            png: png
        ))
    }
}
