//
//  RecordingControlPresenter.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//
//  The in-session mode of the floating bar, laid out like Loom's pill:
//  close, pause, restart and delete (each destructive one asks twice),
//  the red stop pill with the elapsed time, and speaker notes. It shares its panel and chrome
//  with the pre-record picker (RecordingPickerBar), so starting a recording
//  morphs one into the other instead of swapping windows.
//

import AppKit
import SwiftUI

/// Retained as the entry point callers already use; the bar itself is owned
/// by RecordingBarPresenter.
@MainActor
enum RecordingControlPresenter {
    static var shared: RecordingBarPresenter { RecordingBarPresenter.shared }
}

extension RecordingBarPresenter {
    func show(displayID: CGDirectDisplayID?) {
        showRecording(displayID: displayID)
    }
}

// MARK: - Controls

struct RecordingSessionControls: View {
    static let stopTint = Color(red: 0xD6 / 255, green: 0x2E / 255, blue: 0x12 / 255)
    static let pausedTint = Color(red: 0x2A / 255, green: 0x64 / 255, blue: 0xE3 / 255)

    @State private var manager = ScreenRecordingManager.shared
    @AppStorage(ScreendropPreferences.recordingTeleprompterScriptKey) private var script = ""

    private var isPaused: Bool {
        manager.state == .paused
    }

    /// Starting and finishing are both moments where the transport can't
    /// safely be driven - the capture graph is being wired up or torn down.
    private var isSettling: Bool {
        manager.state == .starting || manager.state == .finishing
    }

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            ConfirmingBarButton(
                id: .close,
                title: "Close and delete",
                systemImage: "xmark",
                prompt: "Delete?",
                accessibility: "Close - delete this recording without saving"
            ) {
                manager.deleteRecording()
            }
            .disabled(manager.state == .starting)

            BarActionButton(
                id: .pauseResume,
                title: isPaused ? "Resume recording" : "Pause recording",
                systemImage: isPaused ? "play.fill" : "pause.fill"
            ) {
                if isPaused {
                    manager.resumeRecording()
                } else {
                    manager.pauseRecording()
                }
            }
            .disabled(isSettling)

            ConfirmingBarButton(
                id: .restart,
                title: "Start over",
                systemImage: "arrow.counterclockwise",
                prompt: "Restart?",
                accessibility: "Restart - discard what's recorded and start again"
            ) {
                manager.restartRecording()
            }
            .disabled(isSettling)

            ConfirmingBarButton(
                id: .discard,
                title: "Delete recording",
                systemImage: "trash",
                prompt: "Delete?",
                accessibility: "Delete - discard this recording without saving"
            ) {
                manager.deleteRecording()
            }
            .disabled(manager.state == .starting)

            BarDivider()

            stopPill
                .disabled(isSettling)

            BarDivider()

            BarActionButton(
                id: .teleprompter,
                title: "Speaker notes",
                systemImage: "note.text",
                accessibility: "Show or hide your speaker notes"
            ) {
                TeleprompterController.shared.toggleOverlay(displayID: manager.displayID)
            }
            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var stopTint: Color {
        if isPaused { return Self.pausedTint }
        if manager.sourceIntent == .claude { return RecordingPickerControls.claudeTint }
        return Self.stopTint
    }

    /// Loom's stop button carries the clock, so the one thing you look for
    /// at the end of a take is also the thing you press.
    private var stopPill: some View {
        Button {
            manager.stopRecording()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white)
                    .frame(width: 13, height: 13)
                Text(manager.formattedElapsedTime)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    // Fixed width so 9:59 ticking to 10:00 doesn't nudge the bar.
                    .frame(minWidth: 44, alignment: .leading)
            }
            .foregroundStyle(.white)
            .padding(.leading, 16)
            .padding(.trailing, 18)
            .frame(height: 40)
            .background(Capsule().fill(stopTint))
            .overlay {
                Capsule().fill(LinearGradient(colors: [.clear, .black.opacity(0.14)], startPoint: .center, endPoint: .bottom))
            }
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: isPaused)
        }
        .buttonStyle(BarButtonStyle())
        .help("Stop and save")
        .accessibilityLabel(
            isPaused
                ? "Stop and save - paused at \(manager.formattedElapsedTime)"
                : "Stop and save - \(manager.formattedElapsedTime) recorded"
        )
    }
}

/// A bar button that acts on the second tap. The first turns it into a red
/// "Restart?" or "Delete?" for three seconds.
private struct ConfirmingBarButton: View {
    let id: BarTooltipID
    let title: String
    let systemImage: String
    let prompt: String
    let accessibility: String
    let action: () -> Void

    @State private var confirm = InlineConfirm()

    var body: some View {
        Group {
            if confirm.isArmed {
                Button(action: tap) {
                    Text(prompt)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(RecordingSessionControls.stopTint))
                        .frame(height: BarMetrics.controlSize)
                        .contentShape(Capsule())
                }
                .buttonStyle(BarButtonStyle())
                .accessibilityLabel("\(prompt) Press again to confirm")
                .transition(.opacity)
            } else {
                BarActionButton(id: id, title: title, systemImage: systemImage, accessibility: accessibility, action: tap)
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirm.isArmed)
        .task(id: confirm.armedAt) {
            guard confirm.isArmed else { return }
            try? await Task.sleep(for: .seconds(InlineConfirm.window))
            guard !Task.isCancelled else { return }
            confirm.disarm()
        }
    }

    private func tap() {
        if confirm.tap(at: .now) { action() }
    }
}
