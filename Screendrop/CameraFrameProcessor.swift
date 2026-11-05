//
//  CameraFrameProcessor.swift
//  Screendrop
//
//  Runs each camera frame through the bubble's settings (flip, filter,
//  background) on the camera queue, before the writer and the bubble see
//  it. With nothing set, frames pass through untouched.
//

import CoreImage
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import Vision

nonisolated final class CameraFrameProcessor: @unchecked Sendable {
    struct Settings: Equatable, Sendable {
        var filter: CameraFilter = .none
        var flip = false
        var background: CameraBackground = .none

        var isPassthrough: Bool { self == Settings() }
    }

    private let lock = NSLock()
    private var settings = Settings()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let sequence = VNSequenceRequestHandler()
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var gradients: (size: CGSize, images: [CIImage])?
    private var backgroundImage: (path: String, image: CIImage?)?

    var isPassthrough: Bool { lock.withLock { settings.isPassthrough } }

    func update(_ settings: Settings) {
        lock.withLock { self.settings = settings }
    }

    /// The processed frame, or the same buffer when there's nothing to do
    /// or rendering fails.
    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let settings = lock.withLock { self.settings }
        guard !settings.isPassthrough else { return pixelBuffer }

        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = frame.extent
        var image = frame
        if settings.background != .none {
            image = composite(
                frame: frame,
                mask: personMask(pixelBuffer),
                background: settings.background,
                gradients: gradientImages(size: extent.size),
                image: decodedImage(for: settings.background)
            )
        }
        if let filter = settings.filter.ciFilter() {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        if settings.flip {
            image = image.oriented(.upMirrored)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }

        guard let output = makeBuffer(size: extent.size) else { return pixelBuffer }
        context.render(image, to: output)
        return output
    }

    private func personMask(_ pixelBuffer: CVPixelBuffer) -> CIImage? {
        do {
            try sequence.perform([segmentation], on: pixelBuffer)
        } catch {
            return nil
        }
        return segmentation.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
    }

    private func gradientImages(size: CGSize) -> [CIImage] {
        if let gradients, gradients.size == size { return gradients.images }
        let images = CameraBackground.gradientStops.indices.compactMap { CameraBackground.gradientImage($0, size: size) }
        gradients = (size, images)
        return images
    }

    private func decodedImage(for background: CameraBackground) -> CIImage? {
        guard case .image(let path) = background else { return nil }
        if let backgroundImage, backgroundImage.path == path { return backgroundImage.image }
        let image = CIImage(contentsOf: URL(fileURLWithPath: path))
        backgroundImage = (path, image)
        return image
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}

/// A sample buffer around a pixel buffer, with the timing given.
nonisolated func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &format
    ) == noErr, let format else { return nil }
    var timing = timing
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sample
    ) == noErr else { return nil }
    return sample
}
