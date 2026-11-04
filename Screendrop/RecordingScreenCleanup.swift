//
//  RecordingScreenCleanup.swift
//  Screendrop
//
//  Loom's "clean up my screen" options: a plain backdrop in place of the
//  desktop picture, and a display recording without the menu bar.
//

import AppKit

/// The display minus the menu bar strip, in AppKit global coordinates: what
/// "Hide menu bar and Dock" keeps of a display recording.
nonisolated func menuBarCropRect(frame: CGRect, visibleFrame: CGRect) -> CGRect {
    CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(1, visibleFrame.maxY - frame.minY))
}

/// Swaps the recorded screen's desktop picture for a plain backdrop while a
/// recording runs, and puts the person's own picture back after.
nonisolated enum RecordingWallpaper {
    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        case off, dusk, sea, graphite, paper

        var id: Self { self }

        var title: String {
            switch self {
            case .off: "Off"
            case .dusk: "Dusk"
            case .sea: "Sea"
            case .graphite: "Graphite"
            case .paper: "Paper"
            }
        }

        /// One colour is a solid; two are a top-to-bottom gradient.
        var colors: [CGColor] {
            switch self {
            case .off: []
            case .dusk: [CGColor(srgbRed: 0.33, green: 0.24, blue: 0.62, alpha: 1), CGColor(srgbRed: 0.93, green: 0.48, blue: 0.42, alpha: 1)]
            case .sea: [CGColor(srgbRed: 0.05, green: 0.36, blue: 0.55, alpha: 1), CGColor(srgbRed: 0.42, green: 0.8, blue: 0.78, alpha: 1)]
            case .graphite: [CGColor(srgbRed: 0.2, green: 0.21, blue: 0.23, alpha: 1)]
            case .paper: [CGColor(srgbRed: 0.95, green: 0.94, blue: 0.91, alpha: 1)]
            }
        }
    }

    /// The picture a screen had before a backdrop went up.
    struct RestoreRecord: Codable, Equatable {
        var displayID: UInt32
        var url: URL
        var scaling: UInt?
        var allowClipping: Bool?
        /// sRGB red, green, blue, alpha.
        var fillColor: [CGFloat]?
    }

    static let backdropKey = "recordingBackdrop"
    static let restoreKey = "recordingWallpaperRestore"

    static func stored(in defaults: UserDefaults = .standard) -> Backdrop {
        defaults.string(forKey: backdropKey).flatMap(Backdrop.init(rawValue:)) ?? .off
    }

    /// Saves the screen's picture once, so a restart, which applies again,
    /// never records the backdrop as the picture to go back to.
    static func apply(_ backdrop: Backdrop, to screen: NSScreen) throws {
        guard backdrop != .off, let displayID = screen.displayNumber else { return }
        let workspace = NSWorkspace.shared
        if pendingRecord == nil, let current = workspace.desktopImageURL(for: screen) {
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
            pendingRecord = RestoreRecord(
                displayID: displayID,
                url: current,
                scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
                allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fillColor: fill.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] }
            )
        }
        let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)
        try workspace.setDesktopImageURL(try image(for: backdrop, pixels: pixels), for: screen, options: [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .allowClipping: true,
        ])
    }

    /// Puts the saved picture back. A record whose screen isn't connected
    /// waits for the next launch.
    static func restore() {
        guard let record = pendingRecord else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayNumber == record.displayID }) else { return }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = record.scaling { options[.imageScaling] = scaling }
        if let allowClipping = record.allowClipping { options[.allowClipping] = allowClipping }
        if let rgba = record.fillColor, rgba.count == 4 {
            options[.fillColor] = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(record.url, for: screen, options: options)
            pendingRecord = nil
        } catch {
            NSLog("[Screendrop] Could not restore the desktop picture: \(error)")
        }
    }

    private static var pendingRecord: RestoreRecord? {
        get {
            UserDefaults.standard.data(forKey: restoreKey)
                .flatMap { try? JSONDecoder().decode(RestoreRecord.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: restoreKey)
            } else {
                UserDefaults.standard.removeObject(forKey: restoreKey)
            }
        }
    }

    /// A PNG of the backdrop at the screen's pixel size, drawn once.
    private static func image(for backdrop: Backdrop, pixels: CGSize) throws -> URL {
        let width = max(1, Int(pixels.width)), height = max(1, Int(pixels.height))
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Screendrop/Backdrops", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(backdrop.rawValue)-\(width)x\(height).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        let colors = backdrop.colors
        if colors.count > 1, let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        } else if let color = colors.first {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgImage = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        return url
    }
}

extension NSScreen {
    /// The Core Graphics display this screen shows.
    nonisolated var displayNumber: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
