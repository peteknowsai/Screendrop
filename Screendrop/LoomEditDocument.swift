//
//  LoomEditDocument.swift
//  Screendrop
//
//  The edit a new recording starts with: Loom's plain look rather than
//  Studio's showcase one. No backdrop, padding, rounded card, shadow, zoom
//  or big cursor; the camera where the bubble was, off where you turned it
//  off, full where you filled the screen with it. Studio opens the same
//  document, so anything dressed up later starts from what was shared.
//

import CoreGraphics
import Foundation

enum LoomEditDocument {
    struct Input {
        var captureSizeInPoints: CGSize
        var hasCamera: Bool
        var bubble = BubbleState()
        /// On the take's clock, pauses taken out.
        var hiddenIntervals: [ClosedRange<Double>] = []
        var fullIntervals: [ClosedRange<Double>] = []
        var highlightClicks = true
        var resolution: RecordingUploadResolution = .p1080
        var intent: RecordingSourceIntent = .screen
        var imageOverlays: [RecordingImageOverlay] = []
        var textOverlays: [RecordingTextOverlay] = []
    }

    static func make(input: Input) -> RecordingEditDocument {
        var style = RecordingStudioStyle()
        style.background = .none
        style.padding = 0
        style.cornerRadius = 0
        style.shadow = 0
        style.cursorScale = 1
        style.camera.shrinksDuringZoom = false
        // A Claude Code take is for reading the screen; the face adds nothing.
        style.camera.isVisible = input.hasCamera && input.intent != .claude

        var bubble = input.bubble
        // Full screen and camera-off are spans of the take, carried by cues.
        bubble.isFull = false
        bubble.isHidden = false
        style.camera.layout = input.intent == .cameraOnly
            ? .cameraOnly
            : RecordingCameraLayout(bubble: cameraPlacement(for: bubble, captureSizeInPoints: input.captureSizeInPoints))

        let cues = input.hiddenIntervals.map { RecordingCameraLayoutCue(start: $0.lowerBound, end: $0.upperBound, layout: .screenOnly) }
            + input.fullIntervals.map { RecordingCameraLayoutCue(start: $0.lowerBound, end: $0.upperBound, layout: .cameraOnly) }

        var export = VideoCompressionSettings()
        // Plays everywhere a link gets opened, which HEVC in MOV doesn't.
        export.codec = .h264
        export.container = .mp4
        export.frameRate = .fps30
        export.motionBlurEnabled = false
        export.resolution = switch input.resolution {
        case .p720: .p720
        case .p1080: .p1080
        case .original: .original
        }

        return RecordingEditDocument(
            style: style,
            zoomEnabled: false,
            zoomCues: [],
            cameraLayoutCues: cues.sorted { $0.start < $1.start },
            textOverlays: input.textOverlays,
            imageOverlays: input.imageOverlays,
            exportSettings: export,
            showsClickEffects: input.highlightClicks,
            showsKeystrokes: false
        )
    }
}
