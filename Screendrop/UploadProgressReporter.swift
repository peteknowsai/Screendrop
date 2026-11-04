//
//  UploadProgressReporter.swift
//  Screendrop
//
//  Tells the worker how far a reserved link's upload has got, so anyone who
//  opens the link early sees "Uploading · 64%". The render is the first
//  half of the bar and the upload the second.
//

import Foundation

nonisolated func combinedProgress(render: Double, upload: Double) -> Int {
    func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
    return Int((50 * clamped(render) + 50 * clamped(upload)).rounded())
}

/// One report per two seconds, and always the final 100.
nonisolated struct ProgressThrottle {
    static let interval: TimeInterval = 2
    private var lastSentAt: Date?
    private var lastSent: Int?

    mutating func admits(_ percent: Int, at now: Date) -> Bool {
        guard percent != lastSent else { return false }
        if percent < 100, let lastSentAt, now.timeIntervalSince(lastSentAt) < Self.interval { return false }
        lastSentAt = now
        lastSent = percent
        return true
    }
}

@MainActor
final class UploadProgressReporter {
    private let request: URLRequest
    private var throttle = ProgressThrottle()
    private var render = 0.0
    private var upload = 0.0

    /// `url` is the worker's `/api/uploads/<id>`.
    init(url: URL, token: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        self.request = request
    }

    func report(render fraction: Double) {
        render = fraction
        send()
    }

    func report(upload fraction: Double) {
        render = 1
        upload = fraction
        send()
    }

    /// Best effort: a lost report only leaves the share page's bar behind.
    private func send() {
        let percent = combinedProgress(render: render, upload: upload)
        guard throttle.admits(percent, at: Date()) else { return }
        var request = request
        request.httpBody = Data(#"{"progress":\#(percent)}"#.utf8)
        let report = request
        Task.detached(priority: .utility) {
            _ = try? await URLSession.shared.data(for: report)
        }
    }
}
