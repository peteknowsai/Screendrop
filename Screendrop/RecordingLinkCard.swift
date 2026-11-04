//
//  RecordingLinkCard.swift
//  Screendrop
//
//  The card itself: the take's frame behind frosted buttons, who can watch,
//  how far the upload has got, and Open, Preview, Copy and More.
//

import SwiftUI

struct RecordingLinkCard: View {
    /// A Claude Code take's card is taller, for the ask.
    static func size(hasAsk: Bool) -> CGSize {
        CGSize(width: 300, height: hasAsk ? 246 : 196)
    }

    private var size: CGSize { Self.size(hasAsk: model.ask != nil) }

    let model: RecordingLinkCardModel
    let onClose: () -> Void

    @State private var showsCopied = true

    var body: some View {
        ZStack {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    GlassChip(systemImage: "xmark", accessibility: "Close", action: onClose)
                    Spacer()
                    privacyMenu
                }
                if let ask = model.ask {
                    askBox(ask)
                        .padding(.top, 10)
                } else {
                    status
                        .padding(.horizontal, 4)
                        .padding(.top, 16)
                }
                Spacer(minLength: 0)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        GlassChip(title: "Open", systemImage: "arrow.up.right.square", action: model.open)
                        if model.ask != nil {
                            GlassChip(title: "Copy link", systemImage: "link", action: model.copyLink)
                        } else {
                            GlassChip(title: "Preview", systemImage: "play.fill", action: model.preview)
                        }
                    }
                    GridRow {
                        GlassChip(
                            title: copyTitle,
                            systemImage: showsCopied ? "checkmark" : model.ask != nil ? "terminal" : "link",
                            action: model.copy
                        )
                        moreMenu
                    }
                }
            }
            .padding(14)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 20, y: 14)
        .task(id: model.copies) {
            showsCopied = true
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { showsCopied = false }
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(white: 0.18)
            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width + 20, height: size.height + 20)
                    .blur(radius: 8)
                    .brightness(-0.3)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var copyTitle: String {
        switch (model.ask != nil, showsCopied) {
        case (true, true): "Copied ask"
        case (true, false): "Copy ask"
        case (false, true): "Copied"
        case (false, false): "Copy link"
        }
    }

    /// What went to the clipboard for Claude Code, and the upload under it.
    private func askBox(_ ask: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Copied for Claude Code")
                .font(.system(size: 12, weight: .semibold))
            Text(ask)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0xE8 / 255, green: 0xE9 / 255, blue: 0xEC / 255))
                .lineLimit(3)
                .textSelection(.enabled)
            if model.failed || model.progress != nil {
                status.padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        if model.failed {
            Button(action: model.retry) {
                Text("Upload failed · Try again")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else if let progress = model.progress {
            let percent = Int((progress * 100).rounded())
            VStack(alignment: .leading, spacing: 6) {
                Text("Uploading · \(percent)%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(.white).frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
                }
                .frame(height: 4)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var privacyMenu: some View {
        Menu {
            ForEach(RecordingPrivacyChoice.allCases, id: \.self) { choice in
                Button {
                    model.setPrivacy(choice)
                } label: {
                    if choice == model.privacy {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            GlassChipLabel(
                title: model.privacy == .link ? "Anyone with link" : "Only you",
                systemImage: model.privacy == .link ? "link" : "lock.fill",
                trailingImage: "chevron.down"
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Who can watch")
    }

    private var moreMenu: some View {
        Menu {
            Button("Edit in Studio", action: model.editInStudio)
            Button("Save to Downloads", action: model.saveToDownloads)
            Button("Show in Finder", action: model.showInFinder)
            Divider()
            Button("Delete recording…", role: .destructive, action: model.delete)
        } label: {
            GlassChipLabel(title: "More", systemImage: "ellipsis")
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// The storyboard's frosted white button.
private struct GlassChip: View {
    var title: String?
    let systemImage: String
    var accessibility: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassChipLabel(title: title, systemImage: systemImage)
                .frame(maxWidth: title == nil ? nil : .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility ?? title ?? "")
    }
}

private struct GlassChipLabel: View {
    var title: String?
    let systemImage: String
    var trailingImage: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            if let title {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            if let trailingImage {
                Image(systemName: trailingImage)
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255))
        .padding(.horizontal, title == nil ? 0 : 12)
        .frame(minWidth: 36, minHeight: 36)
        .background(Color.white.opacity(0.62), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
        .contentShape(Capsule())
    }
}
