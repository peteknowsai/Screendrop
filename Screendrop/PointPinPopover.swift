//
//  PointPinPopover.swift
//  Screendrop
//
//  Point, in a take for Claude Code: while it's armed a clear panel takes
//  the next click so it never reaches the app underneath, then a small
//  field asks what that spot is. Neither panel ever shows in the video.
//

import AppKit
import SwiftUI

@MainActor
final class PointPinPresenter {
    static let shared = PointPinPresenter()

    private var catcher: NSPanel?
    private var popover: NSPanel?

    private init() {}

    /// `onPin` gets the Quartz point, the session clock at the click, and
    /// the label; nothing when the label is cancelled.
    func arm(on screen: NSScreen, onPin: @escaping (CGPoint, Double, String) -> Void, onCancel: @escaping () -> Void) {
        disarm()
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
        // A clear window lets clicks through its empty pixels unless told
        // otherwise, and then the click lands in the app underneath.
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = ClickCatcherView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onClick = { [weak self] in
            guard let quartz = CGEvent(source: nil)?.location else { return }
            let time = ScreenRecordingManager.shared.recordingClock ?? 0
            self?.catcher?.orderOut(nil)
            self?.catcher = nil
            self?.askLabel(at: quartz, onDone: { label in
                if let label { onPin(quartz, time, label) } else { onCancel() }
            })
        }
        panel.contentView = view
        PreviewWindowCaptureExclusion.shared.register(window: panel, alwaysHidden: true)
        panel.orderFrontRegardless()
        catcher = panel
    }

    func disarm() {
        catcher?.orderOut(nil)
        catcher = nil
        popover?.orderOut(nil)
        popover = nil
    }

    private func askLabel(at quartz: CGPoint, onDone: @escaping (String?) -> Void) {
        let finish: (String?) -> Void = { [weak self] label in
            self?.popover?.orderOut(nil)
            self?.popover = nil
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            onDone(trimmed?.isEmpty == false ? trimmed : nil)
        }
        let hosting = NSHostingView(rootView: PinLabelField(onDone: finish))
        let size = hosting.fittingSize
        let panel = KeyablePanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        let point = quartzToAppKit(quartz, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        panel.setFrameOrigin(CGPoint(x: point.x - size.width / 2, y: point.y - size.height - 12))
        PreviewWindowCaptureExclusion.shared.register(window: panel, alwaysHidden: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        popover = panel
    }
}

/// Takes typing without bringing Screendrop forward.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ClickCatcherView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

private struct PinLabelField: View {
    let onDone: (String?) -> Void
    @State private var label = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(RecordingPickerControls.claudeTint)
            TextField("What's this? e.g. order total", text: $label)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 220)
                .focused($focused)
                .onSubmit { onDone(label) }
                .onExitCommand { onDone(nil) }
            Button("Pin") { onDone(label) }
                .buttonStyle(.borderedProminent)
                .tint(RecordingPickerControls.claudeTint)
                .controlSize(.small)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassHUD(radius: 14)
        .padding(12)
        // onAppear runs before the panel is key, when focus can't land;
        // a turn later it can, so typing goes straight into the label.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
