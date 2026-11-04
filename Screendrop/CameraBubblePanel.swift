//
//  CameraBubblePanel.swift
//  Screendrop
//
//  The live camera bubble, Loom's way: drag it anywhere and it eases into
//  the nearest corner, with an outline showing which; double-click to fill
//  the screen and again to come back; hover for size, shape, camera off and
//  mute. It never appears in the screen video: the camera reaches the video
//  through camera.mov and the render, which places it where the bubble was.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
@Observable
final class CameraBubblePanel {
    static let shared = CameraBubblePanel()
    /// Room around the bubble inside its window for the shadow and the
    /// drag's scale-up; clicks there fall through.
    static let slack: CGFloat = 28

    var state = BubbleState.stored() {
        didSet {
            guard state != oldValue else { return }
            state.save()
            CameraRecordingManager.shared.noteBubble(isHidden: state.isHidden, isFull: state.isFull)
            layout(animated: true)
        }
    }

    /// Dims the picture while the recording is paused.
    var isPaused = false {
        didSet { bubbleView?.isDimmed = isPaused }
    }

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var bubbleView: CameraBubbleView?
    @ObservationIgnored private var controls: NSPanel?
    @ObservationIgnored private var ghost: NSPanel?
    @ObservationIgnored private(set) var displayID: CGDirectDisplayID?
    @ObservationIgnored private var isOverBubble = false
    @ObservationIgnored private var isOverControls = false
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?

    private init() {}

    private var screen: NSScreen? {
        ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
    }

    func show(displayID: CGDirectDisplayID?, videoLayer: CALayer) {
        if panel != nil, self.displayID == displayID { return }
        hide()
        self.displayID = displayID

        let view = CameraBubbleView(videoLayer: videoLayer)
        view.onDragMoved = { [weak self] center in self?.dragMoved(center: center) }
        view.onDragEnded = { [weak self] center in self?.dragEnded(center: center) }
        view.onDoubleClick = { [weak self] in self?.state.isFull.toggle() }
        view.onClick = { [weak self] in
            guard let self, state.isHidden else { return }
            state.isHidden = false
        }
        view.onHover = { [weak self] inside in
            self?.isOverBubble = inside
            self?.updateControls()
        }
        view.isDimmed = isPaused

        let panel = Self.makePanel(level: .floating)
        panel.contentView = view
        self.panel = panel
        bubbleView = view
        layout(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        hideControlsTask?.cancel()
        for window in [panel, controls, ghost] { window?.orderOut(nil) }
        panel = nil
        controls = nil
        ghost = nil
        bubbleView = nil
        displayID = nil
        isOverBubble = false
        isOverControls = false
    }

    // MARK: Layout

    private func layout(animated: Bool) {
        guard let panel, let visible = screen?.visibleFrame else { return }
        let bubble = bubbleFrame(state: state, in: visible)
        bubbleView?.apply(state, size: bubble.size)
        let frame = bubble.insetBy(dx: -Self.slack, dy: -Self.slack)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        updateControls()
    }

    // MARK: Dragging

    private func dragMoved(center: CGPoint) {
        guard let visible = screen?.visibleFrame else { return }
        hideControls()
        var target = state
        target.corner = snapCorner(center: center, in: visible)
        let frame = bubbleFrame(state: target, in: visible)
        let ghost = ghost ?? makeGhost()
        ghost.setFrame(frame, display: true)
        ghost.orderFrontRegardless()
        panel.map { ghost.order(.below, relativeTo: $0.windowNumber) }
    }

    private func dragEnded(center: CGPoint) {
        ghost?.orderOut(nil)
        ghost = nil
        guard let visible = screen?.visibleFrame else { return }
        let corner = snapCorner(center: center, in: visible)
        if corner == state.corner {
            layout(animated: true)
        } else {
            state.corner = corner
        }
    }

    private func makeGhost() -> NSPanel {
        let ghost = Self.makePanel(level: .floating)
        ghost.ignoresMouseEvents = true
        ghost.contentView = NSHostingView(rootView: BubbleGhost(shape: state.shape, isHidden: state.isHidden))
        self.ghost = ghost
        return ghost
    }

    // MARK: Hover controls

    private func updateControls() {
        let wanted = (isOverBubble || isOverControls) && !state.isFull && !state.isHidden && panel != nil
        if wanted {
            hideControlsTask?.cancel()
            showControls()
        } else {
            // A short grace, so moving from the bubble onto the controls
            // doesn't close them on the way.
            hideControlsTask?.cancel()
            hideControlsTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.hideControls()
            }
        }
    }

    private func showControls() {
        guard let panel, let visible = screen?.visibleFrame else { return }
        let controls = controls ?? makeControls()
        let size = controls.contentView?.fittingSize ?? CGSize(width: 296, height: 120)
        let bubble = panel.frame.insetBy(dx: Self.slack, dy: Self.slack)
        let gap: CGFloat = 8
        // Below the bubble when there's room, above it otherwise.
        let below = bubble.minY - gap - size.height
        let y = below >= visible.minY ? below : bubble.maxY + gap
        let x = min(max(bubble.minX - 14, visible.minX), visible.maxX - size.width)
        controls.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        controls.orderFrontRegardless()
    }

    /// The settings section opened or closed; the panel follows its size
    /// once SwiftUI has laid it out.
    func controlsDidResize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, controls?.isVisible == true else { return }
            showControls()
        }
    }

    private func hideControls() {
        hideControlsTask?.cancel()
        controls?.orderOut(nil)
    }

    private func makeControls() -> NSPanel {
        let controls = Self.makePanel(level: .floating)
        let hosting = HoverTrackingHostingView(rootView: CameraBubbleControls())
        // Sized by hand from fittingSize; left to bridge its size onto the
        // window, the hosting view and the window fight over it.
        hosting.sizingOptions = []
        hosting.onHover = { [weak self] inside in
            self?.isOverControls = inside
            self?.updateControls()
        }
        controls.contentView = hosting
        self.controls = controls
        return controls
    }

    private static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        return panel
    }
}

// MARK: - Bubble view

/// The picture, clipped to the bubble's shape, with a shadow and the
/// camera-off stub. Handles its own dragging so a drag can show the ghost.
private final class CameraBubbleView: NSView {
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    var isDimmed = false {
        didSet { updateDim() }
    }

    private let videoLayer: CALayer
    /// Carries the shadow and the drag's scale-up; scales about its centre.
    private let shell = CALayer()
    private let clip = CALayer()
    private let dim = CALayer()
    private let stub = NSImageView()
    private var isFull = false
    private var isCameraOff = false
    private var grabOffset: CGPoint?
    private var didDrag = false

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.clear.cgColor

        shell.shadowColor = NSColor.black.cgColor
        shell.shadowOpacity = 0.28
        shell.shadowRadius = 15
        shell.shadowOffset = CGSize(width: 0, height: -10)
        clip.masksToBounds = true
        clip.backgroundColor = NSColor.black.cgColor
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0
        videoLayer.removeFromSuperlayer()
        clip.addSublayer(videoLayer)
        clip.addSublayer(dim)
        shell.addSublayer(clip)
        layer?.addSublayer(shell)

        stub.image = NSImage(systemSymbolName: "video.slash.fill", accessibilityDescription: "Camera off")
        stub.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        stub.contentTintColor = .white
        stub.isHidden = true
        addSubview(stub)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Camera bubble. Drag to move, double-click to fill the screen.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var bubbleRect: CGRect {
        bounds.insetBy(dx: CameraBubblePanel.slack, dy: CameraBubblePanel.slack)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bubbleRect.contains(convert(point, from: superview)) ? self : nil
    }

    func apply(_ state: BubbleState, size: CGSize) {
        isFull = state.isFull
        isCameraOff = state.isHidden && !state.isFull
        let short = min(size.width, size.height)
        let radius = isFull ? 0 : (isCameraOff ? short / 2 : state.shape.roundness * short)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        let bounds = CGRect(origin: .zero, size: size)
        shell.bounds = bounds
        shell.position = CGPoint(x: size.width / 2 + CameraBubblePanel.slack, y: size.height / 2 + CameraBubblePanel.slack)
        shell.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shell.shadowOpacity = isFull ? 0 : 0.28
        clip.frame = bounds
        clip.cornerRadius = radius
        clip.backgroundColor = (isCameraOff ? NSColor(white: 0.12, alpha: 0.85) : .black).cgColor
        videoLayer.frame = bounds
        videoLayer.isHidden = isCameraOff
        dim.frame = bounds
        CATransaction.commit()
        stub.isHidden = !isCameraOff
        stub.frame = bounds.offsetBy(dx: CameraBubblePanel.slack, dy: CameraBubblePanel.slack).insetBy(dx: 10, dy: 10)
        setAccessibilityLabel(isCameraOff
            ? "Camera off. Click to show the camera."
            : "Camera bubble. Drag to move, double-click to fill the screen.")
        updateDim()
    }

    private func updateDim() {
        // Loom's paused look: the colour drains and the picture darkens.
        clip.filters = isDimmed
            ? [CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.4])].compactMap { $0 }
            : nil
        dim.opacity = isDimmed ? 0.1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bubbleRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        grabOffset = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFull, let window, let grabOffset else { return }
        if !didDrag {
            didDrag = true
            setLifted(true)
        }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
        onDragMoved?(CGPoint(x: window.frame.midX, y: window.frame.midY))
    }

    override func mouseUp(with event: NSEvent) {
        defer { grabOffset = nil }
        if didDrag, let window {
            setLifted(false)
            onDragEnded?(CGPoint(x: window.frame.midX, y: window.frame.midY))
        } else if event.clickCount == 2 {
            onDoubleClick?()
        } else if event.clickCount == 1 {
            onClick?()
        }
    }

    private func setLifted(_ lifted: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        shell.transform = lifted ? CATransform3DMakeScale(1.03, 1.03, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}

/// Where the bubble will land, while it's being dragged.
private struct BubbleGhost: View {
    let shape: BubbleShape
    let isHidden: Bool

    var body: some View {
        GeometryReader { proxy in
            let short = min(proxy.size.width, proxy.size.height)
            let radius = isHidden ? short / 2 : shape.roundness * short
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(white: 217 / 255).opacity(0.15))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color(white: 232 / 255).opacity(0.8), lineWidth: 1.5)
                }
        }
    }
}

// MARK: - Hover controls

private final class HoverTrackingHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

/// Per the storyboard's B3: the size slider, then settings, the four
/// shapes, camera off and mute.
private struct CameraBubbleControls: View {
    @State private var bubble = CameraBubblePanel.shared
    @State private var recorder = ScreenRecordingManager.shared
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Slider(
                value: Binding(
                    get: { Double(bubble.state.size.rawValue) },
                    set: { bubble.state.size = BubbleSize(rawValue: Int($0.rounded())) ?? .m }
                ),
                in: 0...Double(BubbleSize.allCases.count - 1),
                step: 1
            )
            .controlSize(.small)
            .accessibilityLabel("Bubble size")

            HStack(spacing: 6) {
                iconButton("slider.horizontal.3", label: "Camera settings", isOn: showsSettings) {
                    showsSettings.toggle()
                }

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    ForEach(BubbleShape.allCases, id: \.self) { shape in
                        Button {
                            bubble.state.shape = shape
                        } label: {
                            ShapeGlyph(shape: shape)
                                .frame(width: 36, height: 36)
                                .background {
                                    if bubble.state.shape == shape {
                                        Circle().fill(.white).shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(BarButtonStyle())
                        .accessibilityLabel(shape.title)
                        .accessibilityAddTraits(bubble.state.shape == shape ? .isSelected : [])
                    }
                }
                .padding(4)
                .background(Capsule().fill(Color.black.opacity(0.06)))

                Spacer(minLength: 4)

                if recorder.isActive && !microphoneID.isEmpty {
                    iconButton(recorder.isMicMuted ? "mic.slash" : "mic", label: recorder.isMicMuted ? "Unmute" : "Mute") {
                        recorder.isMicMuted.toggle()
                    }
                }
                iconButton("power", label: "Turn the camera off") {
                    bubble.state.isHidden = true
                }
            }

            if showsSettings {
                CameraSettingsSection()
            }
        }
        .onChange(of: showsSettings) { _, _ in bubble.controlsDidResize() }
        .foregroundStyle(Color(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3F / 255))
        .padding(14)
        .frame(width: 268)
        .glassHUD(radius: 24)
        .padding(14)
    }

    private func iconButton(
        _ systemImage: String,
        label: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.black.opacity(isOn ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(BarButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ShapeGlyph: View {
    let shape: BubbleShape

    var body: some View {
        let (size, radius): (CGSize, CGFloat) = switch shape {
        case .roundedSquare: (CGSize(width: 15, height: 15), 5)
        case .circle: (CGSize(width: 15, height: 15), 7.5)
        case .landscape: (CGSize(width: 19, height: 13), 3)
        case .portrait: (CGSize(width: 13, height: 19), 3)
        }
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(lineWidth: 1.8)
            .frame(width: size.width, height: size.height)
    }
}

extension BubbleShape {
    var title: String {
        switch self {
        case .roundedSquare: "Rounded square"
        case .circle: "Circle"
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        }
    }
}
