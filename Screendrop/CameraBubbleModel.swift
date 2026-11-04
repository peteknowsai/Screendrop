//
//  CameraBubbleModel.swift
//  Screendrop
//
//  The live camera bubble's state and geometry, kept free of AppKit so the
//  check harness can run it. Frames are in AppKit screen points, y up.
//

import CoreGraphics
import Foundation

/// The four shapes in the bubble's hover controls, in their order there.
nonisolated enum BubbleShape: String, Codable, CaseIterable {
    case roundedSquare, circle, landscape, portrait

    /// Width over height. Portrait is 3:4 to match the render's portrait camera.
    var aspect: CGFloat {
        switch self {
        case .roundedSquare, .circle: 1
        case .landscape: 3 / 2
        case .portrait: 3 / 4
        }
    }

    /// Corner radius over the short side.
    var roundness: CGFloat {
        switch self {
        case .circle: 0.5
        case .roundedSquare: 0.3
        case .landscape, .portrait: 0.14
        }
    }
}

/// The five ticks on the size slider.
nonisolated enum BubbleSize: Int, Codable, CaseIterable {
    case xs, s, m, l, xl

    /// The long side.
    var points: CGFloat {
        switch self {
        case .xs: 110
        case .s: 140
        case .m: 180
        case .l: 220
        case .xl: 270
        }
    }
}

/// Same raw values as `RecordingCameraLayout.Corner`.
nonisolated enum BubbleCorner: String, Codable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
}

nonisolated struct BubbleState: Codable, Equatable {
    static let defaultsKey = "recordingBubbleState"
    /// The camera-off stub: a small round button where the bubble was.
    static let hiddenStubSize: CGFloat = 44

    var shape: BubbleShape = .roundedSquare
    var size: BubbleSize = .m
    var corner: BubbleCorner = .bottomLeading
    var isHidden = false
    var isFull = false

    init(
        shape: BubbleShape = .roundedSquare,
        size: BubbleSize = .m,
        corner: BubbleCorner = .bottomLeading,
        isHidden: Bool = false,
        isFull: Bool = false
    ) {
        self.shape = shape
        self.size = size
        self.corner = corner
        self.isHidden = isHidden
        self.isFull = isFull
    }

    /// A value a newer or older build wrote falls back field by field.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = (try? container.decode(BubbleShape.self, forKey: .shape)) ?? .roundedSquare
        size = (try? container.decode(BubbleSize.self, forKey: .size)) ?? .m
        corner = (try? container.decode(BubbleCorner.self, forKey: .corner)) ?? .bottomLeading
        isHidden = (try? container.decode(Bool.self, forKey: .isHidden)) ?? false
        isFull = (try? container.decode(Bool.self, forKey: .isFull)) ?? false
    }

    /// Shape, size and corner carry over; camera-off and full screen are a
    /// take's choices, so a launch starts without them.
    static func stored(in defaults: UserDefaults = .standard) -> BubbleState {
        guard let data = defaults.data(forKey: defaultsKey),
              var state = try? JSONDecoder().decode(BubbleState.self, from: data) else { return BubbleState() }
        state.isHidden = false
        state.isFull = false
        return state
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The bubble's size when it's showing, hidden or not.
    var shownSize: CGSize {
        let long = size.points
        return shape.aspect >= 1
            ? CGSize(width: long, height: (long / shape.aspect).rounded())
            : CGSize(width: (long * shape.aspect).rounded(), height: long)
    }
}

/// The corner whose quadrant holds the point.
nonisolated func snapCorner(center: CGPoint, in frame: CGRect) -> BubbleCorner {
    let leading = center.x < frame.midX
    let top = center.y >= frame.midY
    switch (top, leading) {
    case (true, true): return .topLeading
    case (true, false): return .topTrailing
    case (false, true): return .bottomLeading
    case (false, false): return .bottomTrailing
    }
}

/// Where the bubble sits on the visible part of its screen.
nonisolated func bubbleFrame(state: BubbleState, in visible: CGRect, margin: CGFloat = 36) -> CGRect {
    if state.isFull { return visible }
    let size = state.isHidden
        ? CGSize(width: BubbleState.hiddenStubSize, height: BubbleState.hiddenStubSize)
        : state.shownSize
    let x = state.corner.isLeading ? visible.minX + margin : visible.maxX - margin - size.width
    let y = state.corner.isTop ? visible.maxY - margin - size.height : visible.minY + margin
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

/// The bubble as the render will draw it: everything the Studio layout needs,
/// without the Studio layout's type, which the harness can't compile alone.
nonisolated struct BubbleCameraPlacement: Equatable {
    /// The camera fills the frame (the bubble was double-clicked full).
    var fillsFrame: Bool
    var shape: BubbleShape
    /// Camera width over the capture's short side, the render's own measure.
    var size: Double
    var corner: BubbleCorner
}

nonisolated func cameraPlacement(for state: BubbleState, captureSizeInPoints: CGSize) -> BubbleCameraPlacement {
    let short = max(1, min(captureSizeInPoints.width, captureSizeInPoints.height))
    let size = min(max(Double(state.shownSize.width / short), 0.12), 0.45)
    return BubbleCameraPlacement(fillsFrame: state.isFull, shape: state.shape, size: size, corner: state.corner)
}
