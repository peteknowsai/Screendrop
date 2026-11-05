//
//  RecordingRenderKey.swift
//  Screendrop
//

import Foundation

/// Which flatten a caller wants: one session rendered from one edit
/// document. Two callers with the same key want the same file.
nonisolated enum RecordingRenderKey {
    static func key(sessionPath: String, documentStamp: String) -> String {
        "\(sessionPath)\n\(documentStamp)"
    }
}
