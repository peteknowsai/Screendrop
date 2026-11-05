//
//  ClaudeCodeLog.swift
//  Screendrop
//
//  What a take recorded for Claude Code logs beside the video: each click
//  with the app, window and page it landed on, every page visited, and the
//  spots pinned with Point. Saved as claude-log.json in the session and
//  sent to the worker as the `events` sidecar, in exactly its shape.
//

import CoreGraphics
import Foundation

nonisolated struct ClaudeCodeLog: Codable, Equatable, Sendable {
    nonisolated struct ClickEntry: Codable, Equatable, Sendable {
        var t: Double
        /// Fractions of what was recorded, top-left origin; -1 for a click
        /// outside it, which gets a number but no marker.
        var x: Double
        var y: Double
        var n: Int
        var app: String
        var title: String
        var url: String?

        var isOnScreen: Bool { x >= 0 && y >= 0 }
    }

    nonisolated struct PageEntry: Codable, Equatable, Sendable {
        var t: Double
        var app: String
        var title: String
        var url: String?
    }

    nonisolated struct PinEntry: Codable, Equatable, Sendable {
        var t: Double
        var x: Double
        var y: Double
        var label: String
    }

    static let fileName = "claude-log.json"
    static let clickMarkerDuration: Double = 3
    static let pinDuration: Double = 4

    var clicks: [ClickEntry] = []
    var pages: [PageEntry] = []
    var pins: [PinEntry] = []

    var isEmpty: Bool { clicks.isEmpty && pages.isEmpty && pins.isEmpty }

    /// A Quartz point as a fraction of `captureRect` (Quartz too); nil outside it.
    static func normalize(quartzPoint: CGPoint, captureRect: CGRect) -> CGPoint? {
        guard captureRect.width > 0, captureRect.height > 0,
              captureRect.contains(quartzPoint) else { return nil }
        return CGPoint(
            x: (quartzPoint.x - captureRect.minX) / captureRect.width,
            y: (quartzPoint.y - captureRect.minY) / captureRect.height
        )
    }

    /// A new page only when the app or the title changed.
    mutating func addPage(_ page: PageEntry) {
        if let last = pages.last, last.app == page.app, last.title == page.title { return }
        pages.append(page)
    }

    /// The numbers and pins as they show in the video, on the source clock.
    func textOverlays() -> [RecordingTextOverlay] {
        let teal = RecordingOverlayColor(red: 0x12 / 255, green: 0x80 / 255, blue: 0x8A / 255)
        let numbers = clicks.filter(\.isOnScreen).map { click in
            var overlay = RecordingTextOverlay(start: click.t, end: click.t + Self.clickMarkerDuration)
            overlay.text = "\(click.n)"
            overlay.center = CGPoint(x: click.x, y: click.y)
            overlay.fontSize = 0.035
            overlay.isBold = true
            overlay.hasBackground = true
            overlay.backgroundColor = teal
            return overlay
        }
        let pinned = pins.map { pin in
            var overlay = RecordingTextOverlay(start: pin.t, end: pin.t + Self.pinDuration)
            overlay.text = "Pinned: \(pin.label)"
            overlay.center = CGPoint(x: pin.x, y: pin.y)
            overlay.fontSize = 0.03
            overlay.isBold = true
            overlay.hasBackground = true
            overlay.backgroundColor = teal
            return overlay
        }
        return numbers + pinned
    }

    /// What lands on the clipboard at stop, ready to paste into Claude Code.
    static func ask(url: String) -> String {
        let bare = url.replacingOccurrences(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, with: "", options: .regularExpression)
        return "Fix what this recording shows: " + bare
    }

    /// The same log on another clock, for a cut that moved or dropped time.
    /// Cut-out clicks and pins go; their numbers stay, matching the video. A
    /// page still counts, at the last kept moment, since you were still on it.
    func remapped(_ map: (Double) -> Double?) -> ClaudeCodeLog {
        var log = ClaudeCodeLog()
        log.clicks = clicks.compactMap { click in map(click.t).map { var c = click; c.t = $0; return c } }
        log.pins = pins.compactMap { pin in map(pin.t).map { var p = pin; p.t = $0; return p } }
        for page in pages {
            var moved = page
            moved.t = map(page.t) ?? log.pages.last?.t ?? 0
            log.pages.append(moved)
        }
        return log
    }
}

nonisolated extension RecordingSession {
    var claudeLogURL: URL { directoryURL.appendingPathComponent(ClaudeCodeLog.fileName) }

    /// Present only for a take recorded for Claude Code.
    func loadClaudeLog() -> ClaudeCodeLog? {
        guard let data = try? Data(contentsOf: claudeLogURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeLog.self, from: data)
    }

    func writeClaudeLog(_ log: ClaudeCodeLog) throws {
        try JSONEncoder().encode(log).write(to: claudeLogURL, options: .atomic)
    }
}
