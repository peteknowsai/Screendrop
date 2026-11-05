//
//  CaptureHotkeyAction+Perform.swift
//  Screendrop
//

import Foundation

extension CaptureHotkeyAction {
    func perform() {
        let coordinator = CaptureCoordinator.shared
        let recorder = ScreenRecordingManager.shared
        switch self {
        case .fullscreen: coordinator.captureFullscreen()
        case .window: coordinator.captureWindow()
        case .area: coordinator.captureArea()
        case .textCapture: coordinator.captureText()
        case .screenRecording: RecordingPickerPresenter.shared.toggle()
        case .recordDisplay: coordinator.recordDisplay()
        case .recordWindow: coordinator.recordWindow()
        case .recordArea: coordinator.recordCustomSize()
        case .recordCameraOnly: coordinator.recordCameraOnly()
        case .recordForClaude: coordinator.recordForClaude()
        case .pauseResume:
            recorder.state == .paused ? recorder.resumeRecording() : recorder.pauseRecording()
        case .stopRecording: recorder.stopRecording()
        }
    }
}
