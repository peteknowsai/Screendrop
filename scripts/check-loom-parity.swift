import Carbon.HIToolbox
import Foundation

// The Loom parity checks: pure helpers compiled alongside this file, no
// app launch. Run scripts/check-loom-parity.sh, which holds the swiftc line.
@main
struct LoomParityChecks {
    static func main() {
        checkRenderKey()
        checkHotkeyDefaults()
        print("loom parity checks passed")
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
