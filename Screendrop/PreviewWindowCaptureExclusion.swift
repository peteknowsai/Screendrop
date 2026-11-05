//
//  PreviewWindowCaptureExclusion.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI

@MainActor
final class PreviewWindowCaptureExclusion {
    static let shared = PreviewWindowCaptureExclusion()

    /// Whether Screendrop's UI should be available to screenshot and screen
    /// recording APIs. Opt in via Settings; the pre-record reminder can turn it off.
    static var includesAppWindowsInCaptures: Bool {
        ScreendropPreferences.includeAppWindowsInCaptures
    }

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    /// Windows no capture may ever show, whatever the preference says.
    private let alwaysHiddenWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    /// Registers any Screendrop-owned window whose capture visibility should
    /// follow the production preference.
    func register(window: NSWindow?, alwaysHidden: Bool = false) {
        guard let window else { return }

        registeredWindows.add(window)
        if alwaysHidden { alwaysHiddenWindows.add(window) }
        applyCaptureVisibility(to: window)
    }

    /// Whether a click at an event location landed on one of our own
    /// windows, so the video leaves its click ring out. Windows that let
    /// clicks through don't count, so the pen's full-screen panel only
    /// counts while the pen is on.
    func ownsClick(atQuartz p: CGPoint) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let point = quartzToAppKit(p, primaryScreenHeight: primaryHeight)
        let ours = registeredWindows.allObjects.filter { $0.isVisible && $0.frame.contains(point) }
        guard !ours.isEmpty else { return false }
        // Our Library behind the app being recorded doesn't own that app's clicks.
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let top = ours.first(where: { $0.windowNumber == hit }) else { return false }
        // The pen's click-through panel on top: what counts is what's under it.
        return !top.ignoresMouseEvents || ours.contains { !$0.ignoresMouseEvents }
    }

    /// Applies a changed preference immediately to windows that already
    /// exist, rather than waiting for them to be recreated.
    func refreshRegisteredWindows() {
        for window in registeredWindows.allObjects {
            applyCaptureVisibility(to: window)
        }
    }

    private func applyCaptureVisibility(to window: NSWindow) {
        let shows = Self.includesAppWindowsInCaptures && !alwaysHiddenWindows.contains(window)
        window.sharingType = shows ? .readOnly : .none
    }
}
