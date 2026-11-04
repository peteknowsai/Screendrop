//
//  CloudUploader.swift
//  Screendrop
//
//  Uploads screenshots to R2 via the Screendrop Cloud worker.
//
//  Flow:
//  1. PUT /api/upload for small files, multipart requests for large files
//  2. Worker streams the body or parts directly to R2 via binding
//  3. Worker creates the D1 metadata row, returns the shareable short URL
//
//  The user only needs a worker URL and upload token - no S3 credentials.
//

import AppKit
import AVFoundation
@preconcurrency import CoreMedia
import ImageIO
import UniformTypeIdentifiers

struct CloudUploadResult: Sendable {
    let id: String
    let url: String
    let filename: String
    let size: Int
}

@MainActor
@Observable
final class CloudUploader: NSObject {
    static let shared = CloudUploader()

    /// Upload progress keyed by preview item ID.
    private(set) var uploadProgress: [UUID: Double] = [:]

    /// Set of item IDs currently uploading.
    private(set) var uploadingItems: Set<UUID> = []

    /// Completed upload URLs keyed by preview item ID.
    private(set) var uploadedURLs: [UUID: String] = [:]

    /// Set of item IDs whose upload failed (cleared after shake animation).
    private(set) var failedItemIDs: Set<UUID> = []

    /// Active upload tasks keyed by item ID (for cancellation).
    private var activeTasks: [UUID: Task<CloudUploadResult, any Error>] = [:]

    /// One upload per reserved link at a time: a newer one (a Studio update)
    /// cancels the older, so a slow first upload never lands after it.
    private var uploadsByCloudID: [String: Task<CloudUploadResult, any Error>] = [:]
    private var cloudIDGeneration: [String: Int] = [:]

    private override init() {
        super.init()
    }

    var isConfigured: Bool {
        CloudCredentialStore.shared.isConfigured
    }

    /// Loom's link at record start: an id and a URL for a file that lands later.
    func reserve(mediaType: String, privacy: String, sourceMode: String) async throws -> CloudUploadResult {
        let creds = CloudCredentialStore.shared.snapshot()
        guard creds.isConfigured else { throw CloudUploadError.notConfigured }
        guard let url = URL(string: "\(Self.normalizeWorkerURL(creds.workerURL))/api/uploads/reserve") else {
            throw CloudUploadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Short, because stopping a take waits on it.
        request.timeoutInterval = 5
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mediaType": mediaType, "privacy": privacy, "sourceMode": sourceMode,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudUploadError.invalidResponse }
        guard http.statusCode == 201 else {
            throw CloudUploadError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String, let link = json?["url"] as? String else {
            throw CloudUploadError.invalidResponse
        }
        return CloudUploadResult(id: id, url: link, filename: "", size: 0)
    }

    /// `existingID` puts the file behind a link that already exists.
    func upload(
        itemID: UUID,
        fileURL: URL,
        title: String? = nil,
        socialEnabled: Bool = true,
        existingID: String? = nil
    ) async throws -> CloudUploadResult {
        guard isConfigured else {
            throw CloudUploadError.notConfigured
        }

        let creds = CloudCredentialStore.shared.snapshot()
        let generation = existingID.map { (cloudIDGeneration[$0] ?? 0) + 1 } ?? 0
        let reporter = existingID.flatMap { id in
            URL(string: "\(Self.normalizeWorkerURL(creds.workerURL))/api/uploads/\(id)").map {
                UploadProgressReporter(url: $0, token: creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let existingID {
            cloudIDGeneration[existingID] = generation
            uploadsByCloudID[existingID]?.cancel()
        }
        /// Whether a newer upload to the same link has started since.
        func isSuperseded() -> Bool {
            existingID.map { cloudIDGeneration[$0] != generation } ?? false
        }

        // The Dock mirrors the whole span - the deliverable render (when
        // one is needed) plus the upload itself.
        let dockProgressID = DockExportProgressCoordinator.shared.start()

        // A session recording must upload what the user sees, not the raw
        // screen master: render the saved project into the flattened
        // deliverable first (cached until the edits change).
        var fileURL = fileURL
        let sessionDirectory = fileURL.deletingLastPathComponent()
        // A render is the first half of the bar, the upload the second.
        let rendersFirst = RecordingSession.isSessionDirectory(sessionDirectory)
        if rendersFirst {
            uploadingItems.insert(itemID)
            uploadProgress[itemID] = 0
            do {
                fileURL = try await RecordingSessionRenderer.ensureDeliverable(
                    for: RecordingSession(directoryURL: sessionDirectory),
                    onProgress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.uploadingItems.contains(itemID) else { return }
                            self.uploadProgress[itemID] = fraction / 2
                            DockExportProgressCoordinator.shared.update(dockProgressID, progress: fraction / 2)
                            reporter?.report(render: fraction)
                        }
                    }
                )
                if isSuperseded() { throw CancellationError() }
            } catch {
                DockExportProgressCoordinator.shared.finish(dockProgressID)
                uploadingItems.remove(itemID)
                uploadProgress.removeValue(forKey: itemID)
                if !(error is CancellationError) { failedItemIDs.insert(itemID) }
                throw error
            }
        }

        let fileName = fileURL.lastPathComponent
        let mimeType = mimeTypeForFile(fileURL)
        let isVideo = mimeType.hasPrefix("video/")
        let dimensions: (width: Int, height: Int)?
        let duration: Double?

        if isVideo {
            let videoMeta = await videoDimensions(at: fileURL)
            dimensions = videoMeta.dimensions
            duration = videoMeta.duration
        } else {
            dimensions = imageDimensions(at: fileURL)
            duration = nil
        }

        // No await from here to registering the task, so a newer upload
        // either superseded this one already or will find it and cancel it.
        if isSuperseded() {
            DockExportProgressCoordinator.shared.finish(dockProgressID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            throw CancellationError()
        }

        uploadingItems.insert(itemID)
        uploadProgress[itemID] = rendersFirst ? 0.5 : 0
        let uploadBase = rendersFirst ? 0.5 : 0
        // The ready bar's lock; a reserved link already has its privacy.
        let privacy = isVideo && existingID == nil ? RecordingPrivacyChoice.stored().apiValue : nil

        let uploadTask = Task { [weak self] () throws -> CloudUploadResult in
            let result = try await Self.streamUpload(
                fileURL: fileURL,
                filename: fileName,
                contentType: mimeType,
                mediaType: isVideo ? "video" : "image",
                width: dimensions?.width,
                height: dimensions?.height,
                duration: duration,
                title: title,
                socialEnabled: socialEnabled,
                existingID: existingID,
                privacy: privacy,
                creds: creds,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        let combined = uploadBase + (1 - uploadBase) * fraction
                        self?.uploadProgress[itemID] = combined
                        DockExportProgressCoordinator.shared.update(
                            dockProgressID,
                            progress: combined
                        )
                        reporter?.report(upload: fraction)
                    }
                }
            )

            return result
        }

        activeTasks[itemID] = uploadTask
        if let existingID { uploadsByCloudID[existingID] = uploadTask }
        defer {
            if let existingID, !isSuperseded() { uploadsByCloudID[existingID] = nil }
        }

        do {
            let result = try await uploadTask.value
            DockExportProgressCoordinator.shared.finish(dockProgressID)
            activeTasks.removeValue(forKey: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            uploadedURLs[itemID] = result.url
            if isVideo {
                scheduleSidecarUpload(uploadID: result.id, fileURL: fileURL, title: title, creds: creds)
            }
            return result
        } catch is CancellationError {
            DockExportProgressCoordinator.shared.finish(dockProgressID)
            activeTasks.removeValue(forKey: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            throw CancellationError()
        } catch {
            DockExportProgressCoordinator.shared.finish(dockProgressID)
            activeTasks.removeValue(forKey: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            failedItemIDs.insert(itemID)
            throw error
        }
    }

    /// Ships the share-page extras (poster, title, transcript) after the
    /// video itself is up. Best-effort and detached: the share link is
    /// already usable, sidecars enrich the page when they land.
    private func scheduleSidecarUpload(uploadID: String, fileURL: URL, title: String?, creds: CloudCredentials) {
        let item = ScreenshotHistoryStore.shared.items.first {
            $0.url.standardizedFileURL == fileURL.standardizedFileURL
        }
        let sessionDirectory = item?.recordingSession?.directoryURL
        let createdAt = item?.createdAt ?? Date()
        Task.detached(priority: .utility) {
            await CloudSidecarUploader.uploadVideoSidecars(
                uploadID: uploadID,
                uploadedFileURL: fileURL,
                sessionDirectory: sessionDirectory,
                createdAt: createdAt,
                customTitle: title,
                creds: creds
            )
        }
    }

    func cancelUpload(for itemID: UUID) {
        activeTasks[itemID]?.cancel()
        activeTasks.removeValue(forKey: itemID)
        uploadingItems.remove(itemID)
        uploadProgress.removeValue(forKey: itemID)
    }

    func clearUploadState(for itemID: UUID) {
        uploadingItems.remove(itemID)
        uploadProgress.removeValue(forKey: itemID)
        uploadedURLs.removeValue(forKey: itemID)
        failedItemIDs.remove(itemID)
    }

    func clearFailed(for itemID: UUID) {
        failedItemIDs.remove(itemID)
    }

    // MARK: - Privacy

    /// Who can watch, changed from the Mac with the upload token.
    func setPrivacy(_ privacy: String, uploadID: String) async throws {
        let creds = CloudCredentialStore.shared.snapshot()
        guard creds.isConfigured else { throw CloudUploadError.notConfigured }
        guard let url = URL(string: "\(Self.normalizeWorkerURL(creds.workerURL))/api/uploads/\(uploadID)") else {
            throw CloudUploadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 15
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["privacy": privacy])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudUploadError.invalidResponse }
        guard http.statusCode == 200 else {
            throw CloudUploadError.serverError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Delete

    /// Deletes an upload from the cloud entirely: R2 files (main file, poster,
    /// transcript, storyboard) plus its D1 row and comments/likes/view events.
    /// Irreversible - the share link 404s immediately after.
    func deleteFromCloud(uploadID: String) async throws {
        let creds = CloudCredentialStore.shared.snapshot()
        guard creds.isConfigured else {
            throw CloudUploadError.notConfigured
        }
        try await Self.performDelete(uploadID: uploadID, creds: creds)
    }

    nonisolated private static func performDelete(uploadID: String, creds: CloudCredentials) async throws {
        let workerBase = normalizeWorkerURL(creds.workerURL)
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(workerBase)/api/upload/\(uploadID)") else {
            throw CloudUploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CloudUploadError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw CloudUploadError.serverError(http.statusCode, body)
        }
    }

    // MARK: - Streaming Upload

    /// Uses PUT /api/upload for small files and bounded multipart requests for large files.
    /// Metadata (filename, dimensions, etc.) is passed via headers so the
    /// Worker can stream the body directly to R2 without buffering.
    nonisolated private static func streamUpload(
        fileURL: URL,
        filename: String,
        contentType: String,
        mediaType: String,
        width: Int?,
        height: Int?,
        duration: Double?,
        title: String?,
        socialEnabled: Bool,
        existingID: String?,
        privacy: String?,
        creds: CloudCredentials,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> CloudUploadResult {
        let workerBase = normalizeWorkerURL(creds.workerURL)
        let token = creds.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: "\(workerBase)/api/upload") else {
            throw CloudUploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue(mediaType, forHTTPHeaderField: "X-Media-Type")

        if let width { request.setValue(String(width), forHTTPHeaderField: "X-Width") }
        if let height { request.setValue(String(height), forHTTPHeaderField: "X-Height") }
        if let duration { request.setValue(String(duration), forHTTPHeaderField: "X-Duration") }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            request.setValue(encoded, forHTTPHeaderField: "X-Title")
        }
        request.setValue(socialEnabled ? "true" : "false", forHTTPHeaderField: "X-Social-Enabled")
        // Multipart copies these headers onto its create and part requests.
        if let existingID { request.setValue(existingID, forHTTPHeaderField: "X-Upload-Id") }
        if let privacy { request.setValue(privacy, forHTTPHeaderField: "X-Privacy") }

        let progressDelegate = UploadProgressDelegate { sent, expected in
            guard expected > 0 else { return }
            progress?(min(1, Double(sent) / Double(expected)))
        }

        let responseData: Data
        let response: URLResponse
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size >= 90 * 1024 * 1024 {
            (responseData, response) = try await MultipartCloudUpload.upload(
                fileURL: fileURL, request: request, progress: progress
            )
        } else {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            (responseData, response) = try await URLSession.shared.upload(
                for: request, from: data, delegate: progressDelegate
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudUploadError.invalidResponse
        }

        guard http.statusCode == 201 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw CloudUploadError.serverError(http.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        guard let id = json?["id"] as? String,
              let shareURL = json?["url"] as? String,
              let name = json?["filename"] as? String,
              let fileSize = json?["size"] as? Int else {
            throw CloudUploadError.invalidResponse
        }

        progress?(1)
        return CloudUploadResult(id: id, url: shareURL, filename: name, size: fileSize)
    }

    // MARK: - Helpers

    nonisolated static func normalizeWorkerURL(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)"
    }

    private func mimeTypeForFile(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }

    private func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    nonisolated private func videoDimensions(at url: URL) async -> (dimensions: (width: Int, height: Int)?, duration: Double?) {
        let asset = AVURLAsset(url: url)
        var dims: (width: Int, height: Int)?
        var dur: Double?

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            if let size, let transform {
                let transformed = size.applying(transform)
                dims = (width: Int(abs(transformed.width)), height: Int(abs(transformed.height)))
            } else if let size {
                dims = (width: Int(size.width), height: Int(size.height))
            }
        }

        if let loadedDuration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(loadedDuration)
            if seconds.isFinite, seconds > 0 {
                dur = seconds
            }
        }

        return (dimensions: dims, duration: dur)
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

// MARK: - Errors

enum CloudUploadError: LocalizedError {
    case notConfigured
    case invalidURL
    case networkError(Error)
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud upload is not configured. Set your worker URL and upload token in Settings."
        case .invalidURL:
            "Invalid worker URL."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .serverError(let code, let body):
            "Server error (\(code)): \(body)"
        case .invalidResponse:
            "Invalid response from server."
        }
    }
}
