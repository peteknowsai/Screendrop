//
//  MicrophoneLevelMonitor.swift
//  Screendrop
//

import AVFoundation
import Observation

/// The ready bar's microphone meter: how loud the chosen mic is right now,
/// from 0 to 1. Runs only while the bar is up and only with mic access
/// already granted; it never asks for permission itself.
@MainActor
@Observable
final class MicrophoneLevelMonitor {
    static let shared = MicrophoneLevelMonitor()

    private(set) var level: Double = 0

    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var output: AVCaptureAudioPreviewOutput?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var deviceID: String?

    private init() {}

    func start(deviceID: String) {
        guard deviceID != self.deviceID else { return }
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = RecordingDeviceCatalog.microphone(withID: deviceID),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        // A muted preview output is the cheapest sink that gives the
        // connection live power levels.
        let output = AVCaptureAudioPreviewOutput()
        output.volume = 0
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        self.output = output
        self.deviceID = deviceID
        Task.detached { session.startRunning() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let session { Task.detached { session.stopRunning() } }
        session = nil
        output = nil
        deviceID = nil
        level = 0
    }

    private func sample() {
        guard let power = output?.connections.first?.audioChannels.first?.averagePowerLevel else { return }
        // -50 dB and below reads as silence; 0 dB fills the meter.
        let target = Double(min(max((power + 50) / 50, 0), 1))
        level = target > level ? target : level * 0.8 + target * 0.2
    }
}
