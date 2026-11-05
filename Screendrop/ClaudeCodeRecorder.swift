//
//  ClaudeCodeRecorder.swift
//  Screendrop
//
//  A take for Claude Code logs what a viewer can't see in the pixels: each
//  click gets a number, the app, window title and page it landed on; every
//  page change is noted once a second; Point pins a labelled spot. The
//  presenter sees numbered dots and pins live; the video gets them as text
//  overlays and Claude Code gets the log (ClaudeCodeLog.swift).
//

import AppKit
import ApplicationServices
import SwiftUI

@MainActor
@Observable
final class ClaudeCodeRecorder {
    static let shared = ClaudeCodeRecorder()

    /// Point is armed: the next click pins instead.
    private(set) var isPointing = false

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var log = ClaudeCodeLog()
    /// What's recorded, in Quartz coordinates.
    @ObservationIgnored private var captureRect: CGRect = .zero
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var pageTimer: Timer?
    @ObservationIgnored private var chip: NSPanel?
    @ObservationIgnored private var markers: [NSPanel] = []

    private init() {}

    func begin(captureRect: CGRect, displayID: CGDirectDisplayID?) {
        end()
        log = ClaudeCodeLog()
        isActive = true
        self.captureRect = captureRect
        screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
        showChip()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let location = event.cgEvent?.location
            MainActor.assumeIsolated { self?.noteClick(atQuartz: location) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let location = event.cgEvent?.location
            MainActor.assumeIsolated { self?.noteClick(atQuartz: location) }
            return event
        }) { monitors.append(local) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.notePage() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pageTimer = timer
        notePage()
    }

    /// The take's log, and everything on screen goes.
    func finish() -> ClaudeCodeLog {
        let finished = log
        end()
        return finished
    }

    func end() {
        isActive = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pageTimer?.invalidate()
        pageTimer = nil
        chip?.orderOut(nil)
        chip = nil
        markers.forEach { $0.orderOut(nil) }
        markers = []
        PointPinPresenter.shared.disarm()
        isPointing = false
    }

    func togglePointing() {
        guard isActive, let screen else { return }
        if isPointing {
            PointPinPresenter.shared.disarm()
            isPointing = false
            return
        }
        isPointing = true
        PointPinPresenter.shared.arm(on: screen, onPin: { [weak self] quartz, time, label in
            self?.pin(atQuartz: quartz, time: time, label: label)
        }, onCancel: { [weak self] in
            self?.isPointing = false
        })
    }

    // MARK: - Logging

    /// While paused nothing is logged: the clock isn't moving.
    private var clock: Double? {
        guard isActive, ScreenRecordingManager.shared.state == .recording else { return nil }
        return ScreenRecordingManager.shared.recordingClock
    }

    private func noteClick(atQuartz location: CGPoint?) {
        guard let time = clock, let quartz = location ?? CGEvent(source: nil)?.location,
              !PreviewWindowCaptureExclusion.shared.ownsClick(atQuartz: quartz) else { return }
        let target = Self.window(atQuartz: quartz)
        let point = ClaudeCodeLog.normalize(quartzPoint: quartz, captureRect: captureRect)
        let number = log.clicks.count + 1
        log.clicks.append(ClaudeCodeLog.ClickEntry(
            t: time,
            x: point.map { Double($0.x) } ?? -1,
            y: point.map { Double($0.y) } ?? -1,
            n: number,
            app: target.app,
            title: target.title,
            url: target.url
        ))
        if point != nil {
            flash(ClickNumberDot(number: number), atQuartz: quartz, for: ClaudeCodeLog.clickMarkerDuration)
        }
    }

    private func notePage() {
        guard let time = clock, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = front.processIdentifier
        log.addPage(ClaudeCodeLog.PageEntry(
            t: time,
            app: front.localizedName ?? "",
            title: Self.windows().first { $0.pid == pid }?.title ?? "",
            url: Self.documentURL(pid: pid)
        ))
    }

    private func pin(atQuartz quartz: CGPoint, time: Double, label: String) {
        isPointing = false
        guard isActive else { return }
        // A pin outside what's recorded still gets logged, at the edge.
        let point = ClaudeCodeLog.normalize(quartzPoint: quartz, captureRect: captureRect)
            ?? CGPoint(
                x: min(max((quartz.x - captureRect.minX) / max(captureRect.width, 1), 0), 1),
                y: min(max((quartz.y - captureRect.minY) / max(captureRect.height, 1), 0), 1)
            )
        log.pins.append(ClaudeCodeLog.PinEntry(t: time, x: Double(point.x), y: Double(point.y), label: label))
        flash(PinnedBox(label: label), atQuartz: quartz, for: ClaudeCodeLog.pinDuration)
    }

    // MARK: - What's under the pointer

    private struct WindowInfo {
        let pid: pid_t
        let app: String
        let title: String
        let bounds: CGRect
    }

    /// On-screen app windows, front to back, in Quartz coordinates. Titles
    /// need Screen Recording permission, which a take already has.
    private static func windows() -> [WindowInfo] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return WindowInfo(
                pid: pid,
                app: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds
            )
        }
    }

    /// The window a click landed on: the frontmost one under it, not the
    /// app that was frontmost before the click brought another forward.
    private static func window(atQuartz quartz: CGPoint) -> (app: String, title: String, url: String?) {
        if let hit = windows().first(where: { $0.bounds.contains(quartz) }) {
            return (hit.app, hit.title, documentURL(pid: hit.pid))
        }
        let front = NSWorkspace.shared.frontmostApplication
        return (front?.localizedName ?? "", "", front.flatMap { documentURL(pid: $0.processIdentifier) })
    }

    /// The focused window's document, which for a browser is the page's
    /// address. Needs Accessibility; without it there's simply no URL.
    private static func documentURL(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // A hung app mustn't stall the take.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let windowElement = unsafeDowncast(window, to: AXUIElement.self)
        // The timeout is per element; the window doesn't inherit the app's.
        AXUIElementSetMessagingTimeout(windowElement, 0.25)
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString, &document) == .success
        else { return nil }
        return document as? String
    }

    // MARK: - On screen

    private func showChip() {
        guard let screen else { return }
        let hosting = NSHostingView(rootView: AgentChip())
        let size = hosting.fittingSize
        let panel = Self.overlayPanel(size: size)
        panel.contentView = hosting
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - 8 - size.height))
        panel.orderFrontRegardless()
        chip = panel
    }

    private func flash(_ view: some View, atQuartz quartz: CGPoint, for seconds: Double) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = Self.overlayPanel(size: size)
        panel.contentView = hosting
        let point = quartzToAppKit(quartz, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        panel.setFrameOrigin(CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        panel.orderFrontRegardless()
        markers.append(panel)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            panel.orderOut(nil)
            self?.markers.removeAll { $0 === panel }
        }
    }

    /// Clicks pass through; never in a capture.
    private static func overlayPanel(size: CGSize) -> NSPanel {
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
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        PreviewWindowCaptureExclusion.shared.register(window: panel, alwaysHidden: true)
        return panel
    }
}

private struct AgentChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RecordingPickerControls.claudeTint)
            Text("Recording for Claude Code · clicks and pages are logged")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.label)
        }
        // The panel takes its size from fittingSize; without this the text truncates.
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassHUD(radius: 18)
        .padding(10)
    }
}

private struct ClickNumberDot: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 13, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RecordingPickerControls.claudeTint, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .padding(8)
    }
}

private struct PinnedBox: View {
    let label: String

    var body: some View {
        Text("Pinned: \(label)")
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RecordingPickerControls.claudeTint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(RecordingPickerControls.claudeTint, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            )
            .padding(8)
    }
}
