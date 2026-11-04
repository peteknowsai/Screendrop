//
//  RecordingPickerBar.swift
//  Screendrop
//
//  The pre-record mode of the floating bar, laid out like Loom's: close,
//  the source segment (display, window, custom size, camera only), camera,
//  microphone with a live meter, who can see the link, More, Claude Code
//  mode, and the red Record pill. Window and Custom size hand off to
//  pointing (RecordingSourceTargetPresenter) and dragging
//  (RecordingAreaSelectionPresenter); Record starts the rest through
//  CaptureCoordinator, at which point the same bar morphs into the
//  in-session controls (RecordingControlPresenter).
//
//  The panel, the chrome and the morph live in RecordingBarPresenter.
//

import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI

/// Retained as the entry point callers already use; the bar itself is owned
/// by RecordingBarPresenter.
@MainActor
enum RecordingPickerPresenter {
    static var shared: RecordingBarPresenter { RecordingBarPresenter.shared }
}

extension RecordingBarPresenter {
    func toggle() {
        togglePicker()
    }

    func show() {
        showPicker()
    }
}

// MARK: - Controls

struct RecordingPickerControls: View {
    /// Claude Code mode's teal, the storyboard's agent colour.
    static let claudeTint = Color(red: 0x12 / 255, green: 0x80 / 255, blue: 0x8A / 255)

    @State private var sources = RecordingSourceCatalog.shared
    @State private var target = RecordingSourceTargetPresenter.shared
    @State private var area = RecordingAreaSelectionPresenter.shared
    @State private var recorder = ScreenRecordingManager.shared
    @State private var meter = MicrophoneLevelMonitor.shared
    @State private var cameras = RecordingDeviceCatalog.cameras()
    @AppStorage(ScreendropPreferences.recordingSourceModeKey) private var sourceMode: RecordingSourceMode = .display
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(ScreendropPreferences.recordingSystemAudioKey) private var systemAudio = false
    @AppStorage(ScreendropPreferences.recordingStartDelaySecondsKey) private var startDelaySeconds = 0
    @AppStorage(RecordingPrivacyChoice.defaultsKey) private var privacy: RecordingPrivacyChoice = .link
    @AppStorage(RecordingWallpaper.backdropKey) private var backdrop: RecordingWallpaper.Backdrop = .off
    @AppStorage(ScreendropPreferences.recordingHideMenuBarAndDockKey) private var hideMenuBarAndDock = false
    @AppStorage(ScreendropPreferences.recordingHighlightClicksKey) private var highlightClicks = true
    @AppStorage(ScreendropPreferences.recordingUploadResolutionKey) private var resolution: RecordingUploadResolution = .p1080

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            BarActionButton(
                id: .close,
                title: "Close",
                systemImage: "xmark",
                accessibility: "Close the recorder - Esc"
            ) {
                dismissPicker()
            }

            sourceSegment
                .disabled(CaptureCountdownPresenter.shared.isRunning)

            BarDivider()

            cameraPicker
            microphonePicker
            privacyMenu
            moreMenu
            claudeToggle

            recordPill
                .padding(.leading, 6)
        }
        .task {
            cameras = RecordingDeviceCatalog.cameras()
            await sources.refresh()
        }
        .onAppear { meter.start(deviceID: microphoneID) }
        .onChange(of: microphoneID) { _, id in meter.start(deviceID: id) }
        .onDisappear { meter.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .receive(on: RunLoop.main)) { _ in
            cameras = RecordingDeviceCatalog.cameras()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)
            .receive(on: RunLoop.main)) { _ in
            cameras = RecordingDeviceCatalog.cameras()
        }
    }

    private var canSelectSource: Bool {
        !sources.isLoading && !sources.displays.isEmpty && !CaptureCountdownPresenter.shared.isRunning
    }

    // MARK: Sources

    /// Loom's four-way segment. The selected source sits on a raised puck.
    @ViewBuilder
    private var sourceSegment: some View {
        if sources.errorMessage != nil || (!sources.isLoading && sources.displays.isEmpty) {
            sourcesUnavailable
        } else {
            HStack(spacing: 2) {
                segment(.display, "Display", "display", "Display - record the whole screen")
                segment(.window, "Window", "macwindow", "Window - point at the window to record, then click it")
                segment(.customSize, "Custom size", "rectangle.dashed", "Custom size - drag to select the region to record")
                segment(.cameraOnly, "Camera only", "person.crop.square", "Camera only - record just your camera")
            }
            .padding(3)
            .background(Capsule().fill(Color(nsColor: .labelColor).opacity(0.06)))
            .disabled(sources.isLoading)
        }
    }

    private func segment(_ mode: RecordingSourceMode, _ title: String, _ icon: String, _ accessibility: String) -> some View {
        BarActionButton(
            id: tooltipID(for: mode),
            title: title,
            systemImage: icon,
            isSelected: sourceMode == mode,
            accessibility: accessibility
        ) {
            select(mode)
        }
        .background {
            if sourceMode == mode {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                    .frame(width: 34, height: 34)
            }
        }
    }

    private func tooltipID(for mode: RecordingSourceMode) -> BarTooltipID {
        switch mode {
        case .display: .display
        case .window: .window
        case .customSize: .area
        case .cameraOnly: .cameraOnly
        }
    }

    private var sourcesUnavailable: some View {
        Menu {
            Text(sources.errorMessage ?? "No screens are available.")
            Button("Retry") { Task { await sources.refresh() } }
            if !CGPreflightScreenCaptureAccess() {
                Button("Open Screen Recording Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } label: {
            BarActionLabel(id: .display, title: "Recording sources unavailable - click to retry",
                           systemImage: "exclamationmark.triangle")
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("Recording sources unavailable - retry or open permissions")
    }

    /// Window and Custom size go straight to picking, as Loom's do; a
    /// display with company gets pointing too, so the right screen is chosen.
    private func select(_ mode: RecordingSourceMode) {
        sourceMode = mode
        switch mode {
        case .display:
            if sources.displays.count > 1 { target.begin(.display) } else { cancelPicking() }
        case .window:
            target.begin(.window)
        case .customSize:
            area.begin()
        case .cameraOnly:
            cancelPicking()
            if cameraID.isEmpty, let camera = cameras.first { selectCamera(camera.uniqueID) }
        }
    }

    private func cancelPicking() {
        target.cancel()
        area.cancel()
    }

    // MARK: Record

    private var recordPill: some View {
        Button(action: record) {
            HStack(spacing: 8) {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 14, height: 14)
                Text("Record")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 13)
            .padding(.trailing, 16)
            .frame(height: 36)
            .background(Capsule().fill(Color(red: 0x2A / 255, green: 0x64 / 255, blue: 0xE3 / 255)))
            .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!canSelectSource)
        .help("Record")
        .accessibilityLabel(recordAccessibilityLabel)
    }

    private var recordAccessibilityLabel: String {
        switch sourceMode {
        case .display: "Record this screen"
        case .window: "Record - click the window to record"
        case .customSize: "Record the selected area"
        case .cameraOnly: "Record your camera"
        }
    }

    private func record() {
        RecordingBarPresenter.shared.closeTeleprompter()
        switch sourceMode {
        case .display:
            let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
            guard let display = sources.displays.first(where: { $0.displayID == displayID }) ?? sources.displays.first
            else { NSSound.beep(); return }
            cancelPicking()
            CaptureCoordinator.shared.recordFullscreen(display)
        case .window:
            // The click on a window is what records it.
            if target.mode != .window { target.begin(.window) }
        case .customSize:
            if area.isActive, area.selection != nil { area.commit() } else { area.begin() }
        case .cameraOnly:
            CaptureCoordinator.shared.recordCameraOnly()
        }
    }

    /// Backs out of the picker without recording: stop any warm camera
    /// preview so it doesn't keep running in the background.
    private func dismissPicker() {
        RecordingBarPresenter.shared.hide()
        Task { await CameraRecordingManager.shared.stopPreview() }
    }

    // MARK: Privacy, More, Claude Code

    private var privacyMenu: some View {
        Menu {
            Section("Who can watch") {
                ForEach(RecordingPrivacyChoice.allCases, id: \.self) { choice in
                    Button { privacy = choice } label: {
                        menuSelectionLabel(choice.title, isSelected: privacy == choice)
                    }
                }
            }
        } label: {
            BarActionLabel(
                id: .privacy,
                title: privacy.title,
                systemImage: privacy == .link ? "lock.open" : "lock.fill"
            )
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("Who can watch: \(privacy.title)")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                RecordingBarPresenter.shared.toggleTeleprompter()
            } label: {
                Label("Speaker notes…", systemImage: "note.text")
            }

            Menu {
                ForEach(RecordingWallpaper.Backdrop.allCases) { choice in
                    Button { backdrop = choice } label: {
                        if backdrop == choice {
                            Label(choice.title, systemImage: "checkmark")
                        } else if let swatch = choice.swatch {
                            Label { Text(choice.title) } icon: { Image(nsImage: swatch) }
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                Label("Backgrounds", systemImage: "photo")
            }

            Divider()

            Section("Recording settings") {
                Toggle(isOn: Binding(get: { startDelaySeconds > 0 }, set: { startDelaySeconds = $0 ? 3 : 0 })) {
                    Label("Show countdown", systemImage: "timer")
                }
                Toggle(isOn: $hideMenuBarAndDock) {
                    Label("Hide menu bar and Dock", systemImage: "eye.slash")
                }
                Toggle(isOn: $highlightClicks) {
                    Label("Highlight clicks", systemImage: "cursorarrow.click")
                }
                Toggle(isOn: $systemAudio) {
                    Label("Include system audio", systemImage: "speaker.wave.2")
                }
                Picker(selection: $resolution) {
                    ForEach(RecordingUploadResolution.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Resolution", systemImage: "display")
                }
                .pickerStyle(.menu)
            }

            Divider()

            Button {
                SettingsWindowController.show(tab: .video)
            } label: {
                Label("All settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])
        } label: {
            BarActionLabel(id: .more, title: "More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel("More recording options")
    }

    private var claudeToggle: some View {
        let isOn = recorder.sourceIntent == .claude
        return BarActionButton(
            id: .claude,
            title: isOn ? "Recording for Claude Code" : "Record for Claude Code",
            systemImage: "apple.terminal",
            tint: isOn ? Self.claudeTint : BarMetrics.activeTint,
            isSelected: isOn,
            accessibility: isOn
                ? "Claude Code mode on - clicks are logged and the link starts private"
                : "Claude Code mode off - click to record for Claude Code"
        ) {
            recorder.sourceIntent = isOn ? .screen : .claude
        }
    }

    // MARK: Camera and microphone

    private var cameraTooltip: String {
        guard !cameraID.isEmpty else { return "Camera off" }
        guard let camera = cameras.first(where: { $0.uniqueID == cameraID }) else { return "Camera unavailable" }
        return "Camera: \(camera.localizedName)"
    }

    private var cameraAccessibilityLabel: String {
        guard !cameraID.isEmpty else {
            return "Camera off - click to choose a camera"
        }
        guard let camera = cameras.first(where: { $0.uniqueID == cameraID }) else {
            return "Camera unavailable - click to choose another camera"
        }
        return "Camera on - \(camera.localizedName), click to switch"
    }

    /// The pill only has room for the state, so an attached-but-missing
    /// device is worth calling out there - it's the one case where the icon
    /// alone is misleading.
    private var microphoneTooltip: String {
        guard !microphoneID.isEmpty else { return "Microphone off" }
        guard RecordingDeviceCatalog.microphone(withID: microphoneID) != nil else {
            return "Microphone unavailable"
        }
        return "Microphone on"
    }

    private var microphoneAccessibilityLabel: String {
        guard !microphoneID.isEmpty else {
            return "Microphone off - click to choose an input"
        }
        guard let microphone = RecordingDeviceCatalog.microphone(withID: microphoneID) else {
            return "Microphone unavailable - choose another input"
        }
        return "Microphone on - \(microphone.localizedName)"
    }

    private var cameraPicker: some View {
        Menu {
            Button {
                cameraID = ""
                Task { await CameraRecordingManager.shared.stopPreview() }
            } label: {
                menuSelectionLabel("None", isSelected: cameraID.isEmpty)
            }

            Divider()

            if cameras.isEmpty {
                Text("No cameras available")
            }

            ForEach(cameras, id: \.uniqueID) { device in
                Button {
                    selectCamera(device.uniqueID)
                } label: {
                    menuSelectionLabel(device.localizedName, isSelected: cameraID == device.uniqueID)
                }
            }
        } label: {
            BarActionLabel(
                id: .camera,
                title: cameraTooltip,
                systemImage: cameraID.isEmpty ? "video.slash" : "video.fill",
                tint: cameraID.isEmpty ? BarMetrics.inactiveTint : BarMetrics.activeTint
            )
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel(cameraAccessibilityLabel)
    }

    private var microphonePicker: some View {
        Menu {
            Button {
                microphoneID = ""
            } label: {
                menuSelectionLabel("None", isSelected: microphoneID.isEmpty)
            }

            Divider()

            ForEach(RecordingDeviceCatalog.microphones(), id: \.uniqueID) { device in
                Button {
                    selectMicrophone(device.uniqueID)
                } label: {
                    menuSelectionLabel(
                        device.localizedName,
                        isSelected: microphoneID == device.uniqueID
                    )
                }
            }
        } label: {
            BarActionLabel(
                id: .microphone,
                title: microphoneTooltip,
                systemImage: microphoneID.isEmpty ? "mic.slash" : "mic.fill",
                tint: microphoneID.isEmpty ? BarMetrics.inactiveTint : BarMetrics.activeTint
            )
            .overlay(alignment: .bottom) {
                // Loom's live level: a bar under the mic that moves with your voice.
                if !microphoneID.isEmpty {
                    Capsule()
                        .fill(Color(nsColor: .systemGreen))
                        .frame(width: max(2, 22 * meter.level), height: 3)
                        .frame(width: 22, alignment: .leading)
                        .background(Capsule().fill(BarMetrics.edge))
                        .padding(.bottom, 4)
                        .animation(.linear(duration: 0.08), value: meter.level)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .accessibilityLabel(microphoneAccessibilityLabel)
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func selectCamera(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            let authorized = await RecordingInputAuthorization.ensureAccess(for: .camera)
            cameraID = authorized ? deviceID : ""
            if authorized {
                await warmCameraPreview()
            }
        }
    }

    /// Starts the camera session (and its floating preview) ahead of "Start
    /// Recording", so its exposure/white-balance ramp - the fade-in macOS
    /// shows whenever a capture session starts cold - finishes before
    /// anything is actually being recorded.
    private func warmCameraPreview() async {
        guard !cameraID.isEmpty else { return }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        await CameraRecordingManager.shared.startPreview(deviceID: cameraID, displayID: displayID)
    }

    private func selectMicrophone(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            microphoneID = await RecordingInputAuthorization.ensureAccess(for: .microphone) ? deviceID : ""
        }
    }
}

private extension RecordingWallpaper.Backdrop {
    /// A small round sample of the backdrop for its menu row.
    var swatch: NSImage? {
        guard !colors.isEmpty else { return nil }
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if colors.count > 1, let gradient = NSGradient(colors: colors.compactMap { NSColor(cgColor: $0) }) {
                gradient.draw(in: path, angle: -90)
            } else if let color = colors.first.flatMap({ NSColor(cgColor: $0) }) {
                color.setFill()
                path.fill()
            }
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.stroke()
            return true
        }
    }
}
