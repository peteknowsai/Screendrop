//
//  PenStrokes.swift
//  Screendrop
//
//  What the pen drew during a take, and how each stroke becomes an image
//  overlay on the video. The live strokes are for the presenter only; the
//  video gets one PNG per stroke, shown from mouse-down until five seconds
//  after mouse-up, which is when it fades on screen too.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PenStroke: Equatable, Sendable {
    /// #ff4d2e, the pen's one colour.
    static let rgba: [CGFloat] = [1, 0x4D / 255, 0x2E / 255, 1]
    static let lineWidth: CGFloat = 6
    /// Seconds a stroke stays after mouse-up.
    static let fade: Double = 5

    /// Fractions of the captured area, top-left origin.
    var points: [CGPoint]
    /// Session clock at mouse-down.
    var start: Double
    /// Mouse-down to mouse-up.
    var duration: Double = 0
}

nonisolated func penOverlayTimes(_ stroke: PenStroke, fade: Double = PenStroke.fade) -> (start: Double, end: Double) {
    (stroke.start, stroke.start + stroke.duration + fade)
}

/// Event locations are Quartz, top-left of the primary display; window
/// frames are AppKit, bottom-left of it.
nonisolated func quartzToAppKit(_ p: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
    CGPoint(x: p.x, y: primaryScreenHeight - p.y)
}

/// The ink outline through `points`, in whatever space they're in.
func penInkPath(_ points: [CGPoint], lineWidth: CGFloat, isComplete: Bool) -> CGPath {
    var options = FreehandSettings.simulatePressure(Double(lineWidth))
    options.last = isComplete
    return SvgInk.render(points.map { Vec(Double($0.x), Double($0.y)) }, options).path
}

/// The strokes on a transparent PNG of `canvas` pixels.
func renderPNG(_ strokes: [PenStroke], canvas: CGSize, lineWidth: CGFloat = PenStroke.lineWidth) -> Data? {
    let width = max(1, Int(canvas.width.rounded()))
    let height = max(1, Int(canvas.height.rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let color = CGColor(colorSpace: space, components: PenStroke.rgba) else { return nil }
    // Top-left, like the stroke points.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(color)
    for stroke in strokes {
        let points = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
        context.addPath(penInkPath(points, lineWidth: lineWidth, isComplete: true))
        context.fillPath()
    }
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}
