//
//  CameraSettingsSheet.swift
//  Screendrop
//
//  The camera settings that open inside the bubble's hover panel, per the
//  storyboard's B4: which camera, a filter, flip, and what stands behind
//  you. Changes reach the next camera frame, so the bubble shows them at
//  once and the recording carries them.
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct CameraSettingsSection: View {
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(CameraFilter.defaultsKey) private var filter: CameraFilter = .none
    @AppStorage(ScreendropPreferences.recordingCameraFlipKey) private var flip = false
    @State private var background = CameraBackground.stored()
    @State private var recorder = ScreenRecordingManager.shared
    @State private var cameras = RecordingDeviceCatalog.cameras()

    private static let labelColor = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Camera") {
                Picker("Camera", selection: Binding(get: { cameraID }, set: switchCamera)) {
                    ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    if FakeCamera.movieURL != nil {
                        Text(FakeCamera.name).tag(FakeCamera.deviceID)
                    }
                }
                .labelsHidden()
                // Swapping devices mid-take would split camera.mov.
                .disabled(recorder.isActive)
            }

            section("Filter") {
                Picker("Filter", selection: $filter) {
                    ForEach(CameraFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }

            Toggle("Flip camera", isOn: $flip)
                .toggleStyle(.switch)
                .controlSize(.small)

            section("Background") {
                HStack(spacing: 8) {
                    swatch(.none, help: "No background") {
                        Image(systemName: "nosign")
                    }
                    swatch(.blur, help: "Blur") {
                        Image(systemName: "person.fill")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(LinearGradient(
                                colors: [Color(hex: "#cfd8e2"), Color(hex: "#b8c4d1")],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                    }
                    ForEach(CameraBackground.gradientStops.indices, id: \.self) { index in
                        swatch(.gradient(index), help: "Gradient \(index + 1)") {
                            LinearGradient(
                                colors: [Color(hex: CameraBackground.gradientStops[index].0),
                                         Color(hex: CameraBackground.gradientStops[index].1)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        }
                    }
                    pickedSwatch(isSelected: isColor, help: "Pick a colour", action: pickColor) {
                        if case .color(let hex) = background {
                            Color(hex: hex).overlay { Image(systemName: "eyedropper").foregroundStyle(.white) }
                        } else {
                            Image(systemName: "eyedropper")
                        }
                    }
                    pickedSwatch(isSelected: isImage, help: "Use your own image", action: pickImage) {
                        Image(systemName: "photo.badge.plus")
                    }
                }
            }
        }
        .font(.system(size: 13))
        .onChange(of: filter) { _, _ in CameraRecordingManager.shared.reloadFrameSettings() }
        .onChange(of: flip) { _, _ in CameraRecordingManager.shared.reloadFrameSettings() }
    }

    private var isColor: Bool {
        if case .color = background { true } else { false }
    }

    private var isImage: Bool {
        if case .image = background { true } else { false }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Self.labelColor)
            content()
        }
    }

    private func swatch<Content: View>(
        _ choice: CameraBackground,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        pickedSwatch(isSelected: background == choice, help: help, action: { setBackground(choice) }, content: content)
    }

    private func pickedSwatch<Content: View>(
        isSelected: Bool,
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: action) {
            content()
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 34)
                .background(shape.fill(.white.opacity(0.6)))
                .clipShape(shape)
                .overlay { shape.strokeBorder(.black.opacity(0.1), lineWidth: 1) }
                .padding(2)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(red: 0x2A / 255, green: 0x64 / 255, blue: 0xE3 / 255), lineWidth: 2)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func setBackground(_ choice: CameraBackground) {
        background = choice
        choice.save()
        CameraRecordingManager.shared.reloadFrameSettings()
    }

    private func switchCamera(_ deviceID: String) {
        guard deviceID != cameraID else { return }
        cameraID = deviceID
        let displayID = CameraBubblePanel.shared.displayID
        Task { await CameraRecordingManager.shared.startPreview(deviceID: deviceID, displayID: displayID) }
    }

    private func pickColor() {
        CameraBackgroundColorPicker.shared.open { hex in setBackground(.color(hex: hex)) }
    }

    /// Copies the image in, so moving or deleting the original later
    /// doesn't take the background with it.
    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Screendrop/Backgrounds", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: copy)
            setBackground(.image(path: copy.path))
        } catch {
            NSSound.beep()
            NSLog("[Screendrop] Could not use that background image: \(error)")
        }
    }
}

/// The system colour panel, reporting back as a hex string.
@MainActor
private final class CameraBackgroundColorPicker: NSObject {
    static let shared = CameraBackgroundColorPicker()

    private var onPick: ((String) -> Void)?

    func open(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApp.activate()
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let color = panel.color.usingColorSpace(.sRGB) else { return }
        let hex = String(
            format: "#%02x%02x%02x",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
        onPick?(hex)
    }
}

private extension Color {
    init(hex: String) {
        let color = CameraBackground.ciColor(hex: hex) ?? CIColor(red: 0.5, green: 0.5, blue: 0.5)
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}
