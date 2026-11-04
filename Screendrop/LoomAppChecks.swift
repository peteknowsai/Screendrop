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
        print("loom app checks passed")
        exit(0)
    }

    /// A new recording renders plain, with the camera where the bubble was.
    @MainActor
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
