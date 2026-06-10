import AppKit

enum DebugPathClipboard {
    @discardableResult
    static func copy(_ path: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string)
    }
}
