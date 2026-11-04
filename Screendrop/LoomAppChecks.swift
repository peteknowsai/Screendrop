//
//  LoomAppChecks.swift
//  Screendrop
//
//  Checks for the Loom parity code that needs the whole app module, so
//  they can't live in scripts/check-loom-parity.swift. A Debug build run as
//  `Screendrop --loom-checks` runs them before SwiftUI starts, prints the
//  result and exits; nothing appears on screen.
//

import CoreGraphics
import Foundation

enum LoomAppChecks {
    static var isRequested: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--loom-checks")
        #else
        false
        #endif
    }

    @MainActor
    static func run() -> Never {
        checkLoomEditDocument()
        checkClaudeLog()
        checkCloudID()
        print("loom app checks passed")
        exit(0)
    }

    /// A new recording renders plain, with the camera where the bubble was.
    @MainActor
    /// The Claude Code log: one page per change, the ask, the numbers in
    /// the video, positions within what was recorded, the worker's keys.
    static func checkCloudID() {
        let id = cloudID(fromURL: "https://x.workers.dev/7f3e91c2")
        precondition(id == "7f3e91c2", "a share link's id read as \(id ?? "nil")")
        precondition(cloudID(fromURL: "https://x.workers.dev/library") == nil, "the library page read as a link")
        precondition(cloudID(fromURL: nil) == nil, "no link read as one")
    }

    static func checkClaudeLog() {
        var log = ClaudeCodeLog()
        let page = ClaudeCodeLog.PageEntry(t: 1, app: "Safari", title: "Checkout", url: nil)
        log.addPage(page)
        log.addPage(ClaudeCodeLog.PageEntry(t: 2, app: "Safari", title: "Checkout", url: nil))
        precondition(log.pages.count == 1, "two identical pages in a row were both kept")
        log.addPage(ClaudeCodeLog.PageEntry(t: 3, app: "Safari", title: "Receipt", url: nil))
        precondition(log.pages.count == 2, "a new title wasn't a new page")

        let ask = ClaudeCodeLog.ask(url: "https://screendrop-worker.peteknowsai.workers.dev/7f3e91c2")
        precondition(ask == "Fix what this recording shows: screendrop-worker.peteknowsai.workers.dev/7f3e91c2", ask)

        log.clicks = (1...3).map {
            ClaudeCodeLog.ClickEntry(t: Double($0) * 2, x: 0.5, y: 0.5, n: $0, app: "Safari", title: "Checkout", url: nil)
        }
        let numbers = log.textOverlays()
        precondition(numbers.map(\.text) == ["1", "2", "3"], "click overlays read \(numbers.map(\.text))")
        precondition(numbers.allSatisfy { abs($0.duration - 3) < 0.001 }, "click overlays don't last 3 s")

        let inside = ClaudeCodeLog.normalize(
            quartzPoint: CGPoint(x: 300, y: 200), captureRect: CGRect(x: 200, y: 100, width: 400, height: 200)
        )
        precondition(inside == CGPoint(x: 0.25, y: 0.5), "normalized to \(String(describing: inside))")
        precondition(ClaudeCodeLog.normalize(
            quartzPoint: CGPoint(x: 50, y: 50), captureRect: CGRect(x: 200, y: 100, width: 400, height: 200)
        ) == nil, "a point outside the recording got a position")

        guard let data = try? JSONEncoder().encode(log),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("the log didn't encode")
        }
        precondition(Set(object.keys) == ["clicks", "pages", "pins"], "top-level keys are \(object.keys)")
        let firstClick = (object["clicks"] as? [[String: Any]])?.first ?? [:]
        precondition(Set(firstClick.keys) == ["t", "x", "y", "n", "app", "title"], "click keys are \(firstClick.keys)")
    }

    static func checkLoomEditDocument() {
        let size = CGSize(width: 1440, height: 900)
        let plain = LoomEditDocument.make(input: .init(captureSizeInPoints: size, hasCamera: true))
        let style = plain.style.value
        precondition(!plain.zoomEnabled && plain.zoomCues.isEmpty, "zoom should be off")
        precondition(plain.cameraLayoutCues?.isEmpty == true, "no layout cues by default")
        precondition(style.background == .none && style.padding == 0 && style.cornerRadius == 0 && style.shadow == 0)
        precondition(style.cursorScale == 1, "cursor at natural size")
        precondition(plain.exportSettings?.codec == .h264 && plain.exportSettings?.container == .mp4)
        precondition(plain.exportSettings?.effectiveFrameRate == .fps30 && plain.exportSettings?.effectiveMotionBlurEnabled == false)
        precondition(plain.exportSettings?.resolution == .p1080)
        precondition(style.camera.isVisible && style.camera.layout.kind == .pictureInPicture)
        precondition(style.camera.layout.corner == .bottomLeading && style.camera.layout.shape == .square)

        let cameraOnly = LoomEditDocument.make(input: .init(captureSizeInPoints: size, hasCamera: true, intent: .cameraOnly))
        precondition(cameraOnly.style.value.camera.layout.kind == .camera)

        let claude = LoomEditDocument.make(input: .init(captureSizeInPoints: size, hasCamera: true, intent: .claude))
        precondition(!claude.style.value.camera.isVisible, "Claude Code takes hide the camera")

        let spans = LoomEditDocument.make(input: .init(
            captureSizeInPoints: size,
            hasCamera: true,
            hiddenIntervals: [2...4, 10...12],
            fullIntervals: [6...8]
        ))
        let cues = spans.cameraLayoutCues ?? []
        let screenOnly = cues.filter { $0.layout.kind == .screen }
        precondition(screenOnly.count == 2 && screenOnly[0].start == 2 && screenOnly[0].end == 4 && screenOnly[1].start == 10)
        let full = cues.filter { $0.layout.kind == .camera }
        precondition(full.count == 1 && full[0].start == 6 && full[0].end == 8)

        let quiet = LoomEditDocument.make(input: .init(captureSizeInPoints: size, hasCamera: false, highlightClicks: false, resolution: .p720))
        precondition(quiet.showsClickEffects == false && quiet.exportSettings?.resolution == .p720)
        precondition(!quiet.style.value.camera.isVisible)

        let data = try! CaptureManifest.encoder.encode(spans)
        precondition(try! CaptureManifest.decoder.decode(RecordingEditDocument.self, from: data) == spans, "edit.json round-trip")
    }
}
