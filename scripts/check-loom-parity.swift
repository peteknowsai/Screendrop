import Foundation

// The Loom parity checks: pure helpers compiled alongside this file, no
// app launch. Run scripts/check-loom-parity.sh, which holds the swiftc line.
@main
struct LoomParityChecks {
    static func main() {
        checkRenderKey()
        print("loom parity checks passed")
    }

    /// Two callers share a flatten only for the same session and the same edits.
    static func checkRenderKey() {
        let key = RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s1")
        precondition(key == RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s1"))
        precondition(key != RecordingRenderKey.key(sessionPath: "/a/b.screendroprec", documentStamp: "s2"))
        precondition(key != RecordingRenderKey.key(sessionPath: "/a/c.screendroprec", documentStamp: "s1"))
    }
}
