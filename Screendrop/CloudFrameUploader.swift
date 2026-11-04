//
//  CloudFrameUploader.swift
//  Screendrop
//
//  Stills of an uploaded video for Claude Code's get_frames: two tiny grey
//  thumbnails a second pick the moments (FrameSampler.swift), then only
//  those are decoded at up to 1280 px wide and posted in batches of 100.
//  Best-effort, like the other sidecars.
//

import AVFoundation
import AppKit

nonisolated enum CloudFrameUploader {
    private static let batchSize = 100

    /// `clicks` are seconds on the uploaded video's own timeline.
    static func upload(id: String, movie: URL, clicks: [Double], creds: CloudCredentials) async {
        let asset = AVURLAsset(url: movie)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return }

        let small = AVAssetImageGenerator(asset: asset)
        small.appliesPreferredTrackTransform = true
        small.maximumSize = CGSize(width: 128, height: 128)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        small.requestedTimeToleranceBefore = tolerance
        small.requestedTimeToleranceAfter = tolerance
        let times = stride(from: 0, to: duration, by: 0.5).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var thumbs: [Thumb] = []
        for await result in small.images(for: times) {
            guard let image = try? result.image, let luma = luma(image) else { continue }
            thumbs.append(Thumb(t: result.requestedTime.seconds, luma: luma))
        }
        thumbs.sort { $0.t < $1.t }
        let picked = pickFrames(thumbs, clicks: clicks.filter { $0 >= 0 && $0 < duration })
        guard !picked.isEmpty else { return }

        let full = AVAssetImageGenerator(asset: asset)
        full.appliesPreferredTrackTransform = true
        // Width-bound for screens; a tall portrait take stops at 2560 high.
        full.maximumSize = CGSize(width: 1280, height: 2560)
        let exact = CMTime(seconds: 0.05, preferredTimescale: 600)
        full.requestedTimeToleranceBefore = exact
        full.requestedTimeToleranceAfter = exact

        for start in stride(from: 0, to: picked.count, by: batchSize) {
            let batch = picked[start..<min(start + batchSize, picked.count)]
            var index: [[String: Any]] = []
            var files: [(name: String, filename: String, contentType: String, data: Data)] = []
            for (offset, frame) in batch.enumerated() {
                let time = CMTime(seconds: min(frame.t, duration - 0.05), preferredTimescale: 600)
                guard let image = try? await full.image(at: time).image,
                      let jpeg = NSBitmapImageRep(cgImage: image)
                          .representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { continue }
                let field = "f\(start + offset)"
                var entry: [String: Any] = ["t": frame.t, "field": field]
                if let click = frame.click { entry["click"] = click }
                index.append(entry)
                files.append((field, "\(field).jpg", "image/jpeg", jpeg))
            }
            guard !index.isEmpty, let json = try? JSONSerialization.data(withJSONObject: index) else { continue }
            do {
                try await CloudSidecarUploader.postForm(
                    path: "/api/assets/\(id)/frames",
                    fields: [("index", String(decoding: json, as: UTF8.self))],
                    files: files,
                    creds: creds
                )
            } catch {
                print("Frame upload failed for \(id): \(error)")
                return
            }
        }
    }

    /// The image squeezed into 32×18 grey cells.
    private static func luma(_ image: CGImage) -> [UInt8]? {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
