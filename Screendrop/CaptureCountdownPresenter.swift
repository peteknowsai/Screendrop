//
//  CaptureCountdownPresenter.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Shows a brief centered countdown before a capture is taken, so the user can
/// arrange hover states, menus, etc. Driven by the `captureDelaySeconds`
/// preference. The overlay is fully torn down before the capture fires, so it
/// never appears in the screenshot. A click on it skips the rest, as Loom's
/// does; Esc calls the capture off.
@MainActor
@Observable
final class CaptureCountdownPresenter {
    static let shared = CaptureCountdownPresenter()

    private var panel: NSPanel?

    private init() {}

    private(set) var isRunning = false
    private var runID: UUID?
    private var countdownTask: Task<Bool, Never>?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var skipped = false

    /// False means cancelled or another countdown is already in progress.
    func runIfNeeded(seconds: Int, displayID: CGDirectDisplayID?) async -> Bool {
        guard !isRunning, !Task.isCancelled else { return false }
        guard seconds > 0 else { return true }
        let id = UUID()
        runID = id
        isRunning = true
        skipped = false
        installEscapeMonitors()
        let task = Task { @MainActor in
            guard runID == id, !Task.isCancelled else { return false }
            let model = CaptureCountdownModel(remaining: seconds, total: seconds)
            present(model: model, displayID: displayID)
            do {
                for value in stride(from: seconds, through: 1, by: -1) {
                    try Task.checkCancellation()
                    model.remaining = value
                    try await Task.sleep(for: .seconds(1))
                }
                dismiss()
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                return true
            } catch {
                return false
            }
        }
        countdownTask = task
        let completed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard runID == id else { return false }
        let wasSkipped = skipped
        cancel()
        if wasSkipped {
            // The panel has to be off screen before the capture's first frame.
            try? await Task.sleep(for: .milliseconds(80))
        }
        return (completed || wasSkipped) && !Task.isCancelled
    }

    /// Ends the countdown now and lets the capture go ahead.
    func skip() {
        guard isRunning, countdownTask != nil else { return }
        skipped = true
        dismiss()
        countdownTask?.cancel()
    }

    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        runID = nil
        isRunning = false
        dismiss()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        escapeMonitor = nil
        globalEscapeMonitor = nil
    }

    private func installEscapeMonitors() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func present(model: CaptureCountdownModel, displayID: CGDirectDisplayID?) {
        dismiss()

        let hostingView = NSHostingView(rootView: CaptureCountdownView(model: model, onSkip: { [weak self] in self?.skip() }))
        hostingView.sizingOptions = []
        let size = CaptureCountdownView.panelSize

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
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.setFrame(NSRect(origin: centeredOrigin(size: size, displayID: displayID), size: size), display: true)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func centeredOrigin(size: NSSize, displayID: CGDirectDisplayID?) -> CGPoint {
        let screen = screen(for: displayID) ?? NSScreen.main
        guard let frame = screen?.frame else { return .zero }
        return CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

@MainActor
@Observable
private final class CaptureCountdownModel {
    var remaining: Int
    let total: Int

    init(remaining: Int, total: Int) {
        self.remaining = remaining
        self.total = max(1, total)
    }
}

/// Loom's countdown: a big dark circle in the middle of the screen with the
/// seconds left, and under it how to skip or call it off.
private struct CaptureCountdownView: View {
    static let diameter: CGFloat = 190
    /// The hint sits 120 points below the centre; this leaves it room.
    static let panelSize = NSSize(width: 320, height: 2 * (120 + 24))

    @State var model: CaptureCountdownModel
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Button(action: onSkip) {
                Text("\(model.remaining)")
                    .font(.system(size: 112, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: model.remaining)
                    .frame(width: Self.diameter, height: Self.diameter)
                    .background(Circle().fill(Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.55)))
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Click to skip, Esc to cancel")

            HStack(spacing: 14) {
                Text("Click to skip")
                Text("Esc to cancel")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .offset(y: 120)
            .allowsHitTesting(false)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting in \(model.remaining). Click to skip, Escape to cancel.")
        .accessibilityAddTraits(.isButton)
    }
}
