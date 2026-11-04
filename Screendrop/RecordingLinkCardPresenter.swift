//
//  RecordingLinkCardPresenter.swift
//  Screendrop
//
//  Loom's card after you stop: the link is already on the clipboard, the
//  card sits where the bubble was while the video renders and uploads into
//  that link, and it stays until closed or the next take begins.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class RecordingLinkCardModel {
    let fileURL: URL
    let link: String
    let cloudID: String
    let itemID: UUID
    /// A take for Claude Code: what was copied for it.
    let ask: String?
    var privacy: RecordingPrivacyChoice
    var thumbnail: NSImage?
    /// Bumped on every copy so the "Copied" label restarts its 3 s.
    var copies = 1

    init(fileURL: URL, link: String, cloudID: String, itemID: UUID, ask: String?) {
        self.fileURL = fileURL
        self.link = link
        self.cloudID = cloudID
        self.itemID = itemID
        self.ask = ask
        // Takes for Claude Code start as only you.
        privacy = ask != nil ? .onlyYou : RecordingPrivacyChoice.stored()
    }

    /// 0...1 while rendering or uploading, nil otherwise.
    var progress: Double? {
        let uploader = CloudUploader.shared
        guard uploader.uploadingItems.contains(itemID) else { return nil }
        return uploader.uploadProgress[itemID] ?? 0
    }

    var failed: Bool { CloudUploader.shared.failedItemIDs.contains(itemID) }

    func open() {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    /// History swaps the screen master for the rendered take once it exists;
    /// the card follows, so Preview and Delete act on what was shared.
    private var currentURL: URL {
        guard let session = RecordingDeliverable.session(for: fileURL) else { return fileURL }
        let path = session.directoryURL.standardizedFileURL.path
        return ScreenshotHistoryStore.shared.items.first { $0.recordingSessionPath == path }?.url ?? fileURL
    }

    func preview() {
        QuickLookPreviewPresenter.show(url: currentURL)
    }

    /// The card's main copy: the ask for a Claude Code take, else the link.
    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ask ?? link, forType: .string)
        copies += 1
        RecordingLinkCardPresenter.shared.toast(ask != nil ? "Copied for Claude Code" : "Link copied")
    }

    func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        RecordingLinkCardPresenter.shared.toast("Link copied")
    }

    func retry() {
        CloudUploader.shared.clearUploadState(for: itemID)
        CaptureShelf.shared.uploadLinked(url: fileURL, cloudID: cloudID, itemID: itemID)
    }

    func setPrivacy(_ choice: RecordingPrivacyChoice) {
        let previous = privacy
        guard choice != previous else { return }
        privacy = choice
        Task {
            do {
                try await CloudUploader.shared.setPrivacy(choice.apiValue, uploadID: cloudID)
            } catch {
                privacy = previous
                RecordingLinkCardPresenter.shared.toast("Couldn't change who can watch")
            }
        }
    }

    func editInStudio() {
        CaptureShelfPresenter.shared.onEditVideo?(fileURL)
    }

    func saveToDownloads() {
        Task {
            do {
                let deliverable = try await RecordingDeliverable.resolve(for: fileURL)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let destination = VideoFileActions.uniqueDestinationURL(
                    for: VideoFileActions.exportFileName(for: deliverable),
                    in: downloads
                )
                try await VideoFileActions.save(from: deliverable, to: destination)
                RecordingLinkCardPresenter.shared.toast("Saved to Downloads")
            } catch {
                RecordingLinkCardPresenter.shared.toast("Couldn't save the video")
            }
        }
    }

    func showInFinder() {
        let session = RecordingDeliverable.session(for: fileURL)?.directoryURL ?? fileURL
        NSWorkspace.shared.activateFileViewerSelecting([session])
    }

    /// Both copies go: the take on this Mac and the link.
    func delete() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "It's removed from this Mac, and the link stops working for everyone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CloudUploader.shared.cancelUpload(for: itemID)
        _ = ScreenshotHistoryStore.shared.delete(url: currentURL)
        let id = cloudID
        Task { try? await CloudUploader.shared.deleteFromCloud(uploadID: id) }
        RecordingLinkCardPresenter.shared.hide()
    }
}

@MainActor
final class RecordingLinkCardPresenter {
    static let shared = RecordingLinkCardPresenter()

    /// Room around the card for its shadow.
    private static let shadowRoom: CGFloat = 24
    private static let margin: CGFloat = 36

    private var panel: NSPanel?
    private var toastPanel: NSPanel?
    private var toastTask: Task<Void, Never>?
    private var screen: NSScreen?

    private init() {}

    func show(
        fileURL: URL,
        link: String,
        cloudID: String,
        itemID: UUID,
        ask: String? = nil,
        displayID: CGDirectDisplayID?
    ) {
        hide()
        guard let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main else { return }
        self.screen = screen
        let model = RecordingLinkCardModel(fileURL: fileURL, link: link, cloudID: cloudID, itemID: itemID, ask: ask)
        let cardSize = RecordingLinkCard.size(hasAsk: ask != nil)
        Task {
            model.thumbnail = await VideoPreviewImageLoader.thumbnail(at: fileURL, maxPixelSize: 640)
        }

        let size = CGSize(
            width: cardSize.width + Self.shadowRoom * 2,
            height: cardSize.height + Self.shadowRoom * 2
        )
        let panel = Self.makePanel(size: size)
        let hosting = NSHostingView(rootView: RecordingLinkCard(model: model, onClose: { [weak self] in self?.hide() })
            .padding(Self.shadowRoom))
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting

        // Where the bubble was, in from the screen's usable edges.
        let corner = CameraBubblePanel.shared.state.corner
        let visible = screen.visibleFrame
        let inset = Self.margin - Self.shadowRoom
        panel.setFrameOrigin(CGPoint(
            x: corner.isLeading ? visible.minX + inset : visible.maxX - inset - size.width,
            y: corner.isTop ? visible.maxY - inset - size.height : visible.minY + inset
        ))
        panel.orderFrontRegardless()
        self.panel = panel
        toast(ask != nil ? "Copied for Claude Code" : "Link copied")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        toastTask?.cancel()
        toastPanel?.orderOut(nil)
        toastPanel = nil
    }

    /// A note at the top of the screen for two seconds.
    func toast(_ text: String) {
        toastTask?.cancel()
        toastPanel?.orderOut(nil)
        guard let screen = screen ?? NSScreen.main else { return }
        let hosting = NSHostingView(rootView: LinkCardToast(text: text))
        let size = hosting.fittingSize
        let panel = Self.makePanel(size: size)
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - 14 - size.height))
        panel.orderFrontRegardless()
        toastPanel = panel
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toastPanel?.orderOut(nil)
            self?.toastPanel = nil
        }
    }

    private static func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        return panel
    }
}

private struct LinkCardToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0x1F / 255, green: 0x8A / 255, blue: 0x5B / 255))
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassHUD(radius: 20)
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}
