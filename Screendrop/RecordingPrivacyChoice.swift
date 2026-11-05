//
//  RecordingPrivacyChoice.swift
//  Screendrop
//

import Foundation

/// Who can open a new recording's link, picked from the ready bar's lock.
nonisolated enum RecordingPrivacyChoice: String, CaseIterable {
    case link
    case onlyYou

    static let defaultsKey = "recordingDefaultPrivacy"

    /// The worker's own words for the same two choices.
    var apiValue: String { self == .link ? "link" : "private" }

    var title: String { self == .link ? "Anyone with the link" : "Only you" }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .link
    }
}

/// The ready bar's source segment.
nonisolated enum RecordingSourceMode: String {
    case display, window, customSize, cameraOnly
}

/// How big the shared video is; the local recording keeps its full size.
nonisolated enum RecordingUploadResolution: String, CaseIterable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    case original

    var id: Self { self }
    var title: String { self == .original ? "Original" : rawValue }
}
