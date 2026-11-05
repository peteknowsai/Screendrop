//
//  PenOverlayController.swift
//  Screendrop
//
//  The pen: a clear panel over the recorded display that takes the mouse
//  only while the pen is on. Strokes are for the presenter, fading five
//  seconds after each one ends; the panel stays out of every capture and
//  the video gets the strokes as image overlays at stop (PenStrokes.swift).
//

import AppKit
import QuartzCore

@MainActor
@Observable
final class PenOverlayController {
    static let shared = PenOverlayController()

    private(set) var isOn = false
    /// A take with a screen in it is running.
    private(set) var isAvailable = false

    @ObservationIgnored private var panel: NSPanel?
    /// The recorded area, in AppKit screen coordinates.
    @ObservationIgnored private var captureRect: CGRect = .zero
    @ObservationIgnored private var strokes: [PenStroke] = []

    private init() {}

    /// At the start of a take: the panel waits, clear and letting clicks through.
    func begin(displayID: CGDirectDisplayID?, captureRect: CGRect) {
        end()
        strokes = []
        guard let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main else { return }
        self.captureRect = captureRect

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Over the apps being recorded, under the pill and the bubble.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let canvas = PenCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
        canvas.onStroke = { [weak self] points, began, ended in
            self?.record(points, viewOrigin: screen.frame.origin, began: began, ended: ended)
        }
        panel.contentView = canvas
        PreviewWindowCaptureExclusion.shared.register(window: panel, alwaysHidden: true)
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        isAvailable = true
    }

    func toggle() {
        guard let panel else { return }
        isOn.toggle()
        panel.ignoresMouseEvents = !isOn
    }

    /// The panel goes; the strokes wait for takeStrokes.
    func end() {
        panel?.orderOut(nil)
        panel = nil
        isOn = false
        isAvailable = false
    }

    func takeStrokes() -> [PenStroke] {
        defer { strokes = [] }
        return strokes
    }

    private func record(_ viewPoints: [CGPoint], viewOrigin: CGPoint, began: Double?, ended: Double?) {
        guard let began, let ended, captureRect.width > 0, captureRect.height > 0 else { return }
        // ponytail: a window take maps against where the window was at the
        // start; follow its frames here if people draw on moved windows.
        let points = viewPoints.map {
            CGPoint(
                x: (viewOrigin.x + $0.x - captureRect.minX) / captureRect.width,
                y: (captureRect.maxY - viewOrigin.y - $0.y) / captureRect.height
            )
        }
        guard points.contains(where: { (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return }
        strokes.append(PenStroke(points: points, start: began, duration: max(0, ended - began)))
    }
}

/// Live ink. Each stroke is a shape layer that fades over its last 0.4 s.
private final class PenCanvasView: NSView {
    /// View points, then the session clock at mouse-down and mouse-up.
    var onStroke: (([CGPoint], Double?, Double?) -> Void)?

    private var points: [CGPoint] = []
    private var began: Double?
    private var live: CAShapeLayer?
    private static let fadeOut: CFTimeInterval = 0.4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        points = [convert(event.locationInWindow, from: nil)]
        began = ScreenRecordingManager.shared.recordingClock
        let shape = CAShapeLayer()
        shape.fillColor = NSColor(
            srgbRed: PenStroke.rgba[0], green: PenStroke.rgba[1], blue: PenStroke.rgba[2], alpha: PenStroke.rgba[3]
        ).cgColor
        layer?.addSublayer(shape)
        live = shape
        redraw(isComplete: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard live != nil else { return }
        points.append(convert(event.locationInWindow, from: nil))
        redraw(isComplete: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let shape = live else { return }
        redraw(isComplete: true)
        live = nil
        onStroke?(points, began, ScreenRecordingManager.shared.recordingClock)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + PenStroke.fade - Self.fadeOut
        fade.duration = Self.fadeOut
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        shape.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + PenStroke.fade) { [weak shape] in
            shape?.removeFromSuperlayer()
        }
    }

    private func redraw(isComplete: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live?.path = penInkPath(points, lineWidth: PenStroke.lineWidth, isComplete: isComplete)
        CATransaction.commit()
    }
}
