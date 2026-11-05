//
//  CameraFilter.swift
//  Screendrop
//
//  The camera's look, from the bubble's settings: a colour filter and what
//  stands behind you. Applied to every camera frame before it is written,
//  so the bubble you see is the bubble in the video.
//

import CoreImage
import Foundation

nonisolated enum CameraFilter: String, Codable, CaseIterable {
    case none, warm, cool, mono, vivid

    static let defaultsKey = "recordingCameraFilter"

    var title: String {
        switch self {
        case .none: "None"
        case .warm: "Warm"
        case .cool: "Cool"
        case .mono: "Mono"
        case .vivid: "Vivid"
        }
    }

    /// A fresh filter each call; the caller sets its input image.
    func ciFilter() -> CIFilter? {
        switch self {
        case .none:
            return nil
        case .warm, .cool:
            // A daylight neutral mapped to a lower colour temperature reads
            // warmer, to a higher one cooler; the harness pins the direction.
            let filter = CIFilter(name: "CITemperatureAndTint")
            filter?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter?.setValue(CIVector(x: self == .warm ? 5000 : 8000, y: 0), forKey: "inputTargetNeutral")
            return filter
        case .mono:
            return CIFilter(name: "CIPhotoEffectMono")
        case .vivid:
            let filter = CIFilter(name: "CIColorControls")
            filter?.setValue(1.35, forKey: kCIInputSaturationKey)
            return filter
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> CameraFilter {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .none
    }
}

nonisolated enum CameraBackground: Codable, Equatable {
    case none
    case blur
    /// 0 or 1, the two gradient swatches.
    case gradient(Int)
    case color(hex: String)
    case image(path: String)

    static let defaultsKey = "recordingCameraBackground"

    /// The two gradient swatches, top-left to bottom-right.
    static let gradientStops: [(String, String)] = [("#f3c58f", "#c98fb0"), ("#9fd3c7", "#3b6fe0")]

    static func stored(in defaults: UserDefaults = .standard) -> CameraBackground {
        defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(CameraBackground.self, from: $0) } ?? .none
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// A gradient swatch at the frame's size.
    static func gradientImage(_ index: Int, size: CGSize) -> CIImage? {
        guard gradientStops.indices.contains(index),
              let start = ciColor(hex: gradientStops[index].0),
              let end = ciColor(hex: gradientStops[index].1),
              let filter = CIFilter(name: "CILinearGradient") else { return nil }
        filter.setValue(CIVector(x: 0, y: size.height), forKey: "inputPoint0")
        filter.setValue(CIVector(x: size.width, y: 0), forKey: "inputPoint1")
        filter.setValue(start, forKey: "inputColor0")
        filter.setValue(end, forKey: "inputColor1")
        return filter.outputImage?.cropped(to: CGRect(origin: .zero, size: size))
    }

    static func ciColor(hex: String) -> CIColor? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return CIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255
        )
    }
}

/// You, over the chosen background. With no mask, or no background, the
/// frame is returned as it came. `image` is the decoded `.image` file.
nonisolated func composite(
    frame: CIImage,
    mask: CIImage?,
    background: CameraBackground,
    gradients: [CIImage],
    image: CIImage? = nil
) -> CIImage {
    guard background != .none, let mask else { return frame }
    let extent = frame.extent
    let fill: CIImage
    switch background {
    case .none:
        return frame
    case .blur:
        fill = frame.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: extent)
    case .gradient(let index):
        guard gradients.indices.contains(index) else { return frame }
        fill = gradients[index]
    case .color(let hex):
        guard let color = CameraBackground.ciColor(hex: hex) else { return frame }
        fill = CIImage(color: color).cropped(to: extent)
    case .image:
        guard let image else { return frame }
        fill = cover(image, extent: extent)
    }
    // The person mask comes back smaller than the frame.
    let scaledMask = mask.transformed(by: CGAffineTransform(
        scaleX: extent.width / max(1, mask.extent.width),
        y: extent.height / max(1, mask.extent.height)
    ))
    return frame.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: fill,
        kCIInputMaskImageKey: scaledMask,
    ]).cropped(to: extent)
}

/// Scales an image to fill the extent, cropping what overhangs.
nonisolated private func cover(_ image: CIImage, extent: CGRect) -> CIImage {
    let source = image.extent
    guard source.width > 0, source.height > 0 else { return image }
    let scale = max(extent.width / source.width, extent.height / source.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let offset = CGAffineTransform(
        translationX: extent.midX - scaled.extent.midX,
        y: extent.midY - scaled.extent.midY
    )
    return scaled.transformed(by: offset).cropped(to: extent)
}
