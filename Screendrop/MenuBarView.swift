//
//  MenuBarView.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit
import SwiftUI

/// Loom's menu: record first, then screenshots, then where things went.
struct MenuBarView: View {
    @State private var historyStore = ScreenshotHistoryStore.shared

    var body: some View {
        Group {
            Section("Videos") {
                item("Record Display", "display", .recordDisplay) { CaptureCoordinator.shared.recordDisplay() }
                item("Record Window", "macwindow", .recordWindow) { CaptureCoordinator.shared.recordWindow() }
                item("Record Custom Size", "rectangle.dashed", .recordArea) { CaptureCoordinator.shared.recordCustomSize() }
                item("Record Camera Only", "person.crop.square", .recordCameraOnly) { CaptureCoordinator.shared.recordCameraOnly() }
            }

            Section("Claude Code") {
                item("Record for Claude Code", "apple.terminal", .recordForClaude) { CaptureCoordinator.shared.recordForClaude() }
            }

            Section("Screenshots") {
                item("Capture Area", "viewfinder", .area) { CaptureCoordinator.shared.captureArea() }
                item("Capture Window", "macwindow.on.rectangle", .window) { CaptureCoordinator.shared.captureWindow() }
                item("Capture Display", "display", .fullscreen) { CaptureCoordinator.shared.captureFullscreen() }
                item("Grab Text", "text.viewfinder", .textCapture) { CaptureCoordinator.shared.captureText() }
            }

            Divider()

            Button {
                CloudLibraryLink.open()
            } label: {
                Label("My Library", systemImage: "books.vertical")
            }

            Button {
                CaptureLibraryModel.shared.show()
            } label: {
                Label("Local Captures", systemImage: "photo.on.rectangle")
            }

            Menu {
                uploadsMenuContent
            } label: {
                Label("Uploads", systemImage: "icloud.and.arrow.up")
            }

            Divider()

            Button {
                SettingsWindowController.show(tab: .general)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Quit Screendrop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            historyStore.reload()
        }
    }

    /// A menu row showing the global shortcut the user has bound to `action`.
    private func item(
        _ title: String,
        _ systemImage: String,
        _ action: CaptureHotkeyAction,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
        }
        .keyboardShortcut(CaptureHotkeyPreferences.shortcut(for: action).menuShortcut)
    }

    /// The newest links, so pasting one again is one click away.
    @ViewBuilder
    private var uploadsMenuContent: some View {
        let uploads = historyStore.items
            .filter { $0.cloudURL != nil }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)
        if uploads.isEmpty {
            Text("No uploads yet")
        } else {
            ForEach(Array(uploads)) { item in
                Button(uploadTitle(for: item)) {
                    guard let link = item.cloudURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
            Divider()
        }

        Button("Show All") {
            CloudLibraryLink.open()
        }
    }

    private func uploadTitle(for item: ScreenshotHistoryItem) -> String {
        let name = item.displayName ?? item.fileName
        let shortName = name.count > 34 ? "\(name.prefix(33))…" : name
        let age = RelativeDateTimeFormatter().localizedString(for: item.createdAt, relativeTo: Date())
        return "\(shortName) · \(age)"
    }
}

private extension HotkeyShortcut {
    /// The menu's key hint for this shortcut; nil for keys a menu can't show.
    var menuShortcut: KeyboardShortcut? {
        guard let label = displayTokens.last, label.count == 1,
              let character = label.lowercased().first, character.isASCII else {
            return nil
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers)
    }
}
