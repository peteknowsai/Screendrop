//
//  FakeCameraSource.swift
//  Screendrop
//
//  A camera for machines without one, the test VM above all: a Debug build
//  launched with SCREENDROP_FAKE_CAMERA=<movie> (environment, or
//  `-SCREENDROP_FAKE_CAMERA <movie>` as a launch argument) lists "Test
//  camera" and loops that movie into the camera engine, stamped on the host
//  clock like a real camera's frames. Release builds never see it.
//

import AVFoundation
@preconcurrency import CoreMedia

nonisolated enum FakeCamera {
    static let deviceID = "fake"
    static let name = "Test camera"

    static var movieURL: URL? {
        #if DEBUG
        let path = ProcessInfo.processInfo.environment["SCREENDROP_FAKE_CAMERA"]
            ?? UserDefaults.standard.string(forKey: "SCREENDROP_FAKE_CAMERA")
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
        #else
        return nil
        #endif
    }

    static func isFake(_ deviceID: String) -> Bool {
        deviceID == Self.deviceID && movieURL != nil
    }
}

/// Feeds the movie's frames at 30 fps, from the start again at its end.
/// Runs entirely on `queue`.
nonisolated final class FakeCameraSource: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let queue: DispatchQueue
    private let handler: (CMSampleBuffer) -> Void
    private var timer: DispatchSourceTimer?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?

    init(asset: AVAsset, track: AVAssetTrack, queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) {
        self.asset = asset
        self.track = track
        self.queue = queue
        self.handler = handler
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            reader?.cancelReading()
            reader = nil
            output = nil
        }
    }

    private func tick() {
        guard let pixelBuffer = nextFrame() ?? restartAndRead(),
              let sample = Self.sample(pixelBuffer, at: CMClockGetTime(CMClockGetHostTimeClock())) else { return }
        handler(sample)
    }

    private func nextFrame() -> CVPixelBuffer? {
        if reader == nil { openReader() }
        return output?.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer)
    }

    private func restartAndRead() -> CVPixelBuffer? {
        openReader()
        return output?.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer)
    }

    private func openReader() {
        reader?.cancelReading()
        reader = nil
        output = nil
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }
        self.reader = reader
        self.output = output
    }

    private static func sample(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
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
}
