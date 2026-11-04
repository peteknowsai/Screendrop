import Carbon.HIToolbox
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
        print("loom parity checks passed")
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

    /// Two callers share a flatten only for the same session and the same edits.
    static func checkRenderKey() {
        let key = RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s1")
        precondition(key == RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s1"))
        precondition(key != RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s2"))
        precondition(key != RecordingRenderKey.key(sessionPath: "/a/c.screendroprec", documentStamp: "s1"))
    }
}
