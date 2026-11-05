//
//  CloudUploadOptions.swift
//  Screendrop
//
//  The title + "allow comments & likes" choice offered right before a
//  manual cloud upload. Auto-upload (after-capture, no user interaction)
//  skips this entirely and just uses the remembered default toggle.
//

import SwiftUI

struct CloudUploadOptions: Sendable {
    var title: String
    var socialEnabled: Bool

    /// `nil` title means "let the worker fall back to the filename (or,
    /// for recordings, the auto-generated 'Screen Recording - …' title)".
    var trimmedTitleOrNil: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Remembers the last-chosen "allow comments & likes" toggle across
/// uploads (including background auto-uploads, which never show the
/// popover) so the common case doesn't require re-deciding every time.
enum CloudUploadPreferences {
    private static let socialEnabledKey = "cloudUploadDefaultSocialEnabled"

    static var lastSocialEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: socialEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: socialEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: socialEnabledKey) }
    }
}

/// Small popover form shown from an upload/share button: a title field
/// (prefilled with a suggested default, editable) and a single toggle
/// that turns comments + likes on or off for this upload. Confirming
/// remembers the toggle choice as the default for next time.
struct CloudUploadOptionsPopover: View {
    let suggestedTitle: String
    /// Replacing the video behind a link that already exists.
    let isUpdate: Bool
    let onConfirm: (CloudUploadOptions) -> Void

    @State private var title: String
    @State private var socialEnabled = CloudUploadPreferences.lastSocialEnabled
    @Environment(\.dismiss) private var dismiss

    init(suggestedTitle: String = "", isUpdate: Bool = false, onConfirm: @escaping (CloudUploadOptions) -> Void) {
        self.suggestedTitle = suggestedTitle
        self.isUpdate = isUpdate
        self.onConfirm = onConfirm
        _title = State(initialValue: suggestedTitle)
    }

    var body: some View {
        InspectorPopover(
            title: isUpdate ? "Update Video" : "Share Options",
            message: isUpdate
                ? "Replaces the video behind your link. Comments, views and the link stay."
                : "Uploads to your cloud and copies a share link.",
            confirmTitle: isUpdate ? "Update video" : "Upload",
            onCancel: { dismiss() },
            onConfirm: {
                if !isUpdate { CloudUploadPreferences.lastSocialEnabled = socialEnabled }
                let options = CloudUploadOptions(title: title, socialEnabled: socialEnabled)
                dismiss()
                onConfirm(options)
            }
        ) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                    InspectorGroupLabel("Title")
                    TextField("Title", text: $title, prompt: Text(isUpdate ? "Keep the current title" : "Untitled"))
                        .labelsHidden()
                        .lineLimit(1)
                        .inspectorTextField()
                }

                // An update keeps the link's own settings; change them on the web.
                if !isUpdate {
                    InspectorToggleRow("Allow comments & likes", isOn: $socialEnabled)
                }
            }
        }
    }
}

/// Wraps any trigger content in a button that opens `CloudUploadOptionsPopover`
/// before firing `onUpload`. Drop-in replacement for a plain
/// `Button(action: onUpload) { ... }` at a manual upload/share call site.
struct CloudUploadButton<Label: View>: View {
    let suggestedTitle: String
    let onUpload: (CloudUploadOptions) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            label()
        }
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            CloudUploadOptionsPopover(suggestedTitle: suggestedTitle, onConfirm: onUpload)
        }
    }
}
