//
//  RecordingPausedToast.swift
//  Screendrop
//
//  The note at the top of the screen while a recording is paused, so a
//  pause is never mistaken for a take that's still running.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingPausedToast {
    static let shared = RecordingPausedToast()

    private var panel: NSPanel?

    private init() {}

    func show(displayID: CGDirectDisplayID?) {
        hide()
        let shortcut = CaptureHotkeyPreferences.shortcut(for: .pauseResume).displayTokens.joined()
        let hosting = NSHostingView(rootView: PausedToastView(shortcut: shortcut))
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = hosting
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        if let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main {
            // Just under the menu bar, centred, as the storyboard has it.
            let top = screen.visibleFrame.maxY - 14
            panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: top - size.height))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PausedToastView: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0x1F / 255, green: 0x8A / 255, blue: 0x5B / 255))
            Text("Paused · \(shortcut) to resume")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassHUD(radius: 20)
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}
