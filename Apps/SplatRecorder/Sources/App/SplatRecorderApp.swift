import AppKit
import Darwin
import SwiftUI

@main
@MainActor
enum SplatRecorderApp {
    private static var delegate: AppDelegate?

    static func main() {
        if runAxisDebugIfRequested() {
            return
        }
        if runValidationIfRequested() {
            return
        }

        #if arch(x86_64)
        let alert = NSAlert()
        alert.messageText = "Requires Apple Silicon"
        alert.informativeText = "MetalSplatter is unsupported on Intel architecture (x86_64)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        return
        #endif

        let app = NSApplication.shared
        let appDelegate = AppDelegate(autoOpenURL: autoOpenURL)
        delegate = appDelegate

        app.delegate = appDelegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static func runAxisDebugIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--debug-axis" else { return false }
        guard args.count >= 3 else {
            fputs("Usage: SplatRecorder --debug-axis <output-dir>\n", stderr)
            exit(2)
        }

        let outputDirectory = URL(fileURLWithPath: args[2], isDirectory: true)
        let completion = DispatchSemaphore(value: 0)
        let box = ValidationResultBox()

        Task.detached {
            do {
                try await SplatRecorderAxisValidation.run(outputDirectory: outputDirectory)
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            completion.signal()
        }

        completion.wait()
        switch box.result {
        case .success:
            return true
        case .failure(let error):
            fputs("SplatRecorder axis debug failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        case .none:
            fputs("SplatRecorder axis debug failed without an error\n", stderr)
            exit(1)
        }
    }

    private static func runValidationIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--validate" else { return false }
        guard args.count >= 4 else {
            fputs("Usage: SplatRecorder --validate <input.ply|splat|spz> <output-dir>\n", stderr)
            exit(2)
        }

        let inputURL = URL(fileURLWithPath: args[2])
        let outputDirectory = URL(fileURLWithPath: args[3], isDirectory: true)
        let completion = DispatchSemaphore(value: 0)
        let box = ValidationResultBox()

        Task.detached {
            do {
                try await SplatRecorderValidation.run(inputURL: inputURL, outputDirectory: outputDirectory)
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            completion.signal()
        }

        completion.wait()
        switch box.result {
        case .success:
            return true
        case .failure(let error):
            fputs("SplatRecorder validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        case .none:
            fputs("SplatRecorder validation failed without an error\n", stderr)
            exit(1)
        }
    }

    /// First command-line argument treated as splat file path for auto-load.
    private static var autoOpenURL: URL? {
        let args = CommandLine.arguments
        guard args.count > 1 else { return nil }
        return URL(fileURLWithPath: args[1])
    }
}

private final class ValidationResultBox: @unchecked Sendable {
    var result: Result<Void, Error>?
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let autoOpenURL: URL?
    private var window: NSWindow?

    init(autoOpenURL: URL?) {
        self.autoOpenURL = autoOpenURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rootView = SplatRecorderContentView(autoOpenURL: autoOpenURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SplatRecorder"
        window.center()
        window.minSize = NSSize(width: 800, height: 600)
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = NSHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
