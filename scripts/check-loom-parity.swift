import AppKit
import Carbon.HIToolbox
import CoreImage
import Foundation

// The Loom parity checks: pure helpers compiled alongside this file, no
// app launch. Run scripts/check-loom-parity.sh, which holds the swiftc line.
@main
struct LoomParityChecks {
    static func main() {
        checkRenderKey()
        checkHotkeyDefaults()
        checkPrivacyChoice()
        checkWallpaper()
        checkInlineConfirm()
        checkBubble()
        checkCameraFilter()
        checkPen()
        checkProgress()
        checkFrameSampler()
        print("loom parity checks passed")
    }

    /// One pixel of `image`, as 0-255 RGBA.
    static func pixel(_ image: CIImage, context: CIContext) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &out,
            rowBytes: 4,
            bounds: CGRect(x: 1, y: 1, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return out
    }

    /// Filters and backgrounds persist, and a background replaces only
    /// what the mask says isn't you.
    static func checkCameraFilter() {
        for filter in CameraFilter.allCases {
            let data = try! JSONEncoder().encode(filter)
            precondition(try! JSONDecoder().decode(CameraFilter.self, from: data) == filter)
        }
        precondition(CameraFilter.none.ciFilter() == nil)
        precondition(CameraFilter.mono.ciFilter()?.name == "CIPhotoEffectMono")
        precondition(CameraFilter.stored(in: emptyDefaults()) == .none)

        let backgrounds: [CameraBackground] = [.none, .blur, .gradient(1), .color(hex: "#ff0000"), .image(path: "/tmp/a.png")]
        for background in backgrounds {
            let data = try! JSONEncoder().encode(background)
            precondition(try! JSONDecoder().decode(CameraBackground.self, from: data) == background)
        }
        precondition(CameraBackground.stored(in: emptyDefaults()) == .none)

        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let frame = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent)
        let black = CIImage(color: .black).cropped(to: extent)
        let white = CIImage(color: .white).cropped(to: extent)

        let untouched = composite(frame: frame, mask: white, background: .none, gradients: [])
        precondition(untouched.extent == extent && pixel(untouched, context: context) == pixel(frame, context: context))

        let replaced = pixel(composite(frame: frame, mask: black, background: .color(hex: "#ff0000"), gradients: []), context: context)
        precondition(replaced[0] > 240 && replaced[2] < 15, "no person should show the red fill, got \(replaced)")
        let kept = pixel(composite(frame: frame, mask: white, background: .color(hex: "#ff0000"), gradients: []), context: context)
        precondition(kept[2] > 240 && kept[0] < 15, "the person should stay, got \(kept)")

        // Warm has to read warmer than cool on the same grey.
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        func through(_ filter: CameraFilter) -> [UInt8] {
            let f = filter.ciFilter()!
            f.setValue(grey, forKey: kCIInputImageKey)
            return pixel(f.outputImage!.cropped(to: extent), context: context)
        }
        let warm = through(.warm), cool = through(.cool)
        precondition(warm[0] > warm[2] && cool[2] > cool[0], "warm \(warm) should lean red, cool \(cool) blue")
    }

    /// The bubble snaps by quadrant, keeps its long side, and maps onto the
    /// render's camera at the size you saw it.
    static func checkBubble() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        precondition(snapCorner(center: CGPoint(x: 200, y: 800), in: screen) == .topLeading)
        precondition(snapCorner(center: CGPoint(x: 1300, y: 100), in: screen) == .bottomTrailing)

        let defaults = BubbleState()
        precondition(defaults.shape == .roundedSquare && defaults.size == .m && defaults.corner == .bottomLeading)
        precondition(BubbleState.stored(in: emptyDefaults()) == defaults)

        let circle = cameraPlacement(for: BubbleState(shape: .circle, size: .m), captureSizeInPoints: CGSize(width: 1440, height: 900))
        precondition(!circle.fillsFrame && circle.shape == .circle && abs(circle.size - 0.2) < 0.0001, "\(circle)")
        precondition(cameraPlacement(for: BubbleState(shape: .landscape), captureSizeInPoints: screen.size).shape == .landscape)
        precondition(cameraPlacement(for: BubbleState(isFull: true), captureSizeInPoints: screen.size).fillsFrame)
        let tiny = cameraPlacement(for: BubbleState(size: .xs), captureSizeInPoints: CGSize(width: 3840, height: 2160))
        precondition(abs(tiny.size - 0.12) < 0.0001, "xs on 4K should clamp to 0.12, got \(tiny.size)")

        let saved = BubbleState(shape: .portrait, size: .xl, corner: .topTrailing, isHidden: true, isFull: false)
        let data = try! JSONEncoder().encode(saved)
        precondition(try! JSONDecoder().decode(BubbleState.self, from: data) == saved)
        let odd = #"{"shape":"hexagon","size":4,"corner":"topTrailing"}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(BubbleState.self, from: odd)
        precondition(decoded.shape == .roundedSquare && decoded.size == .xl && decoded.corner == .topTrailing)

        let suite = emptyDefaults()
        saved.save(in: suite)
        let relaunched = BubbleState.stored(in: suite)
        precondition(relaunched.shape == .portrait && relaunched.size == .xl, "shape and size should persist")
        precondition(!relaunched.isHidden && !relaunched.isFull, "camera-off and full screen should not persist")

        let portrait = bubbleFrame(state: BubbleState(shape: .portrait, size: .m), in: screen)
        precondition(portrait.height == 180 && portrait.width == 135, "\(portrait)")
        precondition(portrait.minX == 36 && portrait.minY == 36, "bottom-left with a 36 pt margin, got \(portrait)")
        precondition(bubbleFrame(state: BubbleState(isFull: true), in: screen) == screen)
    }

    /// Restart and delete act on the second tap inside three seconds only.
    static func checkInlineConfirm() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var confirm = InlineConfirm()
        precondition(!confirm.tap(at: start), "the first tap acted")
        precondition(confirm.isArmed)
        precondition(confirm.tap(at: start.addingTimeInterval(2.9)), "a second tap in time did nothing")
        precondition(!confirm.isArmed, "confirming left it armed")

        precondition(!confirm.tap(at: start.addingTimeInterval(10)))
        precondition(!confirm.tap(at: start.addingTimeInterval(13.5)), "a late tap acted")
        precondition(confirm.isArmed, "a late tap should arm it again")
        precondition(confirm.tap(at: start.addingTimeInterval(14)))
    }

    static func emptyDefaults() -> UserDefaults {
        let name = "loom-parity-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The lock menu's choice reaches the worker as its own two words.
    static func checkPrivacyChoice() {
        precondition(RecordingPrivacyChoice.link.apiValue == "link")
        precondition(RecordingPrivacyChoice.onlyYou.apiValue == "private")
        precondition(RecordingPrivacyChoice.stored(in: emptyDefaults()) == .link)
    }

    static func checkWallpaper() {
        let record = RecordingWallpaper.RestoreRecord(
            displayID: 1,
            url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Solid Colors/Black.png"),
            scaling: 3,
            allowClipping: true,
            fillColor: [0.1, 0.2, 0.3, 1]
        )
        let data = try! JSONEncoder().encode(record)
        precondition(try! JSONDecoder().decode(RecordingWallpaper.RestoreRecord.self, from: data) == record)
        precondition(RecordingWallpaper.Backdrop(rawValue: "nope") == nil)
        precondition(RecordingWallpaper.stored(in: emptyDefaults()) == .off)

        let crop = menuBarCropRect(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875)
        )
        precondition(crop == CGRect(x: 0, y: 0, width: 1512, height: 945), "crop is \(crop)")
    }

    /// Loom's recording keys (Q7); the screenshot keys stay as they were.
    static func checkHotkeyDefaults() {
        let optionShift: HotkeyShortcut.Modifiers = [.option, .shift]
        let expected: [(CaptureHotkeyAction, HotkeyShortcut)] = [
            (.recordDisplay, HotkeyShortcut(modifiers: optionShift, keyCode: kVK_ANSI_1)),
            (.recordWindow, HotkeyShortcut(modifiers: optionShift, keyCode: kVK_ANSI_2)),
            (.recordArea, HotkeyShortcut(modifiers: optionShift, keyCode: kVK_ANSI_3)),
            (.recordCameraOnly, HotkeyShortcut(modifiers: optionShift, keyCode: kVK_ANSI_4)),
            (.recordForClaude, HotkeyShortcut(modifiers: optionShift, keyCode: kVK_ANSI_5)),
            (.pauseResume, HotkeyShortcut(modifiers: [.control, .option], keyCode: kVK_ANSI_R)),
            (.stopRecording, HotkeyShortcut(modifiers: [.command, .control], keyCode: kVK_ANSI_C)),
        ]
        for (action, shortcut) in expected {
            precondition(action.defaultShortcut == shortcut, "\(action) default is \(action.defaultShortcut.displayString)")
        }
        let defaults = CaptureHotkeyAction.allCases.map(\.defaultShortcut)
        precondition(Set(defaults).count == defaults.count, "two actions share a default shortcut")
        let ids = CaptureHotkeyAction.allCases.map(\.hotKeyID)
        precondition(Set(ids).count == ids.count, "two actions share a hot key id")
        let sessionOnly = CaptureHotkeyAction.allCases.filter(\.isSessionOnly)
        precondition(sessionOnly == [.pauseResume, .stopRecording], "session-only actions are \(sessionOnly)")
    }

    /// Stills for Claude Code: scene changes, a floor of one per 10 s, clicks.
    static func checkFrameSampler() {
        let still = [UInt8](repeating: 100, count: 32 * 18)
        func moved(_ cells: Int) -> [UInt8] {
            var luma = still
            for i in 0..<cells { luma[i] = 200 }
            return luma
        }
        let times = (0..<60).map { Double($0) * 0.5 }
        let quiet = pickFrames(times.map { Thumb(t: $0, luma: still) })
        precondition(quiet.map(\.t) == [0, 10, 20], "a still video gave \(quiet.map(\.t))")

        let scene = pickFrames(times.map { Thumb(t: $0, luma: $0 >= 7 ? moved(20) : still) })
        precondition(scene.map(\.t) == [0, 7, 17, 27], "a scene change at 7 s gave \(scene.map(\.t))")
        let flicker = pickFrames(times.map { Thumb(t: $0, luma: $0 >= 7 ? moved(5) : still) })
        precondition(flicker.map(\.t) == [0, 10, 20], "5 changed cells counted as a scene: \(flicker.map(\.t))")

        let clicked = pickFrames(times.map { Thumb(t: $0, luma: still) }, clicks: [3.0])
        precondition(clicked.contains { $0.t == 3.25 && $0.click == 1 }, "click frame missing: \(clicked)")

        let busy = (0..<1000).map { Thumb(t: Double($0) * 0.5, luma: $0.isMultiple(of: 2) ? still : moved(100)) }
        let cappedFrames = pickFrames(busy, clicks: (0..<50).map { Double($0) * 9 + 0.1 })
        precondition(cappedFrames.count <= 400, "\(cappedFrames.count) frames is over the cap")
        precondition(cappedFrames.filter { $0.click != nil }.count == 50, "the cap dropped clicks")
    }

    /// The share page's bar: render then upload, at most one report per 2 s.
    static func checkProgress() {
        precondition(combinedProgress(render: 1, upload: 0.28) == 64, "\(combinedProgress(render: 1, upload: 0.28))")
        precondition(combinedProgress(render: 0.5, upload: 0) == 25)
        var throttle = ProgressThrottle()
        let start = Date(timeIntervalSince1970: 0)
        precondition(throttle.admits(10, at: start))
        precondition(!throttle.admits(20, at: start.addingTimeInterval(1)), "two reports inside 2 s")
        precondition(throttle.admits(30, at: start.addingTimeInterval(2.1)))
        precondition(throttle.admits(100, at: start.addingTimeInterval(2.2)), "the final 100 waited")
        precondition(!throttle.admits(100, at: start.addingTimeInterval(5)), "100 sent twice")
    }

    /// Each stroke is its own overlay, gone five seconds after mouse-up, and
    /// its PNG is drawn top-left like the points.
    static func checkPen() {
        let first = penOverlayTimes(PenStroke(points: [], start: 1.0))
        let second = penOverlayTimes(PenStroke(points: [], start: 3.0))
        precondition(first.start == 1 && first.end == 6, "first stroke \(first)")
        precondition(second.start == 3 && second.end == 8, "second stroke \(second)")
        let held = penOverlayTimes(PenStroke(points: [], start: 2, duration: 1.5))
        precondition(held.end == 8.5, "a held stroke fades from mouse-up, \(held)")
        precondition(quartzToAppKit(CGPoint(x: 10, y: 100), primaryScreenHeight: 900) == CGPoint(x: 10, y: 800))

        let diagonal = PenStroke(
            points: (0...20).map { CGPoint(x: 0.1 + 0.04 * Double($0), y: 0.1 + 0.04 * Double($0)) },
            start: 0
        )
        guard let png = renderPNG([diagonal], canvas: CGSize(width: 200, height: 100)),
              let bitmap = NSBitmapImageRep(data: png) else { preconditionFailure("the pen PNG did not render") }
        precondition(bitmap.pixelsWide == 200 && bitmap.pixelsHigh == 100, "pen PNG is \(bitmap.size)")
        func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
        precondition(alpha(100, 50) > 0.5, "no ink in the middle")
        precondition(alpha(170, 85) > 0.5, "no ink near the bottom-right end")
        precondition(alpha(170, 15) == 0, "the stroke is drawn upside down")
        precondition(alpha(2, 97) == 0, "ink in the corner")
    }

    /// Two callers share a flatten only for the same session and the same edits.
    static func checkRenderKey() {
        let key = RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s1")
        precondition(key == RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s1"))
        precondition(key != RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s2"))
        precondition(key != RecordingRenderKey.key(sessionPath: "/a/c.screendroprec", documentStamp: "s1"))
    }
}
