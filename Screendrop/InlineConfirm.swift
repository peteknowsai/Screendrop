//
//  InlineConfirm.swift
//  Screendrop
//

import Foundation

/// Loom's two-tap confirm for restart and delete: the first tap arms the
/// button, a second within the window acts, and a late one arms it again.
nonisolated struct InlineConfirm {
    static let window: TimeInterval = 3

    private(set) var armedAt: Date?

    var isArmed: Bool { armedAt != nil }

    /// True only for the tap that confirms.
    mutating func tap(at now: Date) -> Bool {
        if let armedAt, now.timeIntervalSince(armedAt) <= Self.window {
            self.armedAt = nil
            return true
        }
        armedAt = now
        return false
    }

    mutating func disarm() {
        armedAt = nil
    }
}
