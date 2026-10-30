import SwiftUI
import AppKit
import CoreAudio

// Menu bar mark: the brand wave — a parametric-EQ response curve with two
// band-handle nodes — rendered as a template image so it adapts to the menu
// bar appearance. Same curve as the app icon and the in-panel logo.
private enum MenuBarMark {
    static func response(_ t: Double) -> Double {
        sin(t * 2 * .pi)   // one sine cycle — matches the app icon
    }

    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let cgContext = NSGraphicsContext.current?.cgContext else { return false }

            let x0 = rect.width * 0.10
            let x1 = rect.width * 0.90
            let midY = rect.height * 0.50
            let amp = rect.height * 0.30

            func point(_ t: Double) -> NSPoint {
                NSPoint(x: x0 + (x1 - x0) * CGFloat(t),
                        y: midY + amp * CGFloat(response(t)))   // y-up (unflipped): a crest lifts up
            }

            let wave = NSBezierPath()
            let steps = 64
            for i in 0...steps {
                let p = point(Double(i) / Double(steps))
                if i == 0 { wave.move(to: p) } else { wave.line(to: p) }
            }
            wave.lineWidth = 1.9
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            NSColor.black.setStroke()
            wave.stroke()

            // Band handles: punch a hole through the curve, then ring it.
            let r: CGFloat = 2.0
            for t in [0.25, 0.75] {
                let c = point(t)
                let box = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                cgContext.setBlendMode(.destinationOut)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: box).fill()
                cgContext.setBlendMode(.normal)
                let ring = NSBezierPath(ovalIn: box)
                ring.lineWidth = 0.9
                NSColor.black.setStroke()
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// `MenuBarExtra(.window)` builds its content lazily on first open, so a
/// `.task` there would not run until the user clicks the menu bar. The launch
/// update check hangs off the application lifecycle instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let quitWarningSuppressedKey = "quitWarning.suppressed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared.checkAtLaunch()
    }

    /// A DAC whose volume Hertzwise applies plays at its own full level once
    /// Hertzwise is gone, so a quit asks first. Logout, restart and shutdown
    /// never wait on it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitReason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason)
        guard quitReason == nil,
              !UserDefaults.standard.bool(forKey: Self.quitWarningSuppressedKey) else { return .terminateNow }
        let controlled = Set(OutputPaths.shared.volumeControlledUIDs)
        let devices = AudioDeviceController().outputDevices().filter { controlled.contains($0.uid) }
        guard !devices.isEmpty else { return .terminateNow }
        let names = devices.map(\.name)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Quit Hertzwise?")
        alert.informativeText = L10n.format(
            "%@ ignores the Mac's volume, and Hertzwise applies it. After quitting, anything playing there plays at the device's full level.",
            names.joined(separator: ", "))
        alert.addButton(withTitle: L10n.string("Pause and Quit"))
        let quit = alert.addButton(withTitle: L10n.string("Quit"))
        quit.hasDestructiveAction = true
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("Don't ask again")
        NSApp.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.quitWarningSuppressedKey)
        }
        guard response == .alertFirstButtonReturn else { return .terminateNow }
        NotificationCenter.default.post(name: SampleRateModel.pauseRequest, object: nil)
        quitWhenSilent(devices: Set(devices.map(\.id)), deadline: Date().addingTimeInterval(2))
        return .terminateLater
    }

    /// Quits once nothing else plays to `devices`; the path keeps muting
    /// them until then. If playback hasn't stopped by `deadline`, stays.
    private func quitWhenSilent(devices: Set<AudioObjectID>, deadline: Date) {
        guard AudioProcessMonitor.isOtherProcessOutputting(to: devices) else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        guard Date() < deadline else {
            NSApp.reply(toApplicationShouldTerminate: false)
            let alert = NSAlert()
            alert.messageText = L10n.string("Playback didn't pause, so Hertzwise is still running.")
            alert.runModal()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.quitWhenSilent(devices: devices, deadline: deadline)
        }
    }
}

/// One Hertzwise at a time: each taps everything but itself, so two would
/// mute each other's output and the DAC would go silent. Checked before
/// SwiftUI builds the models, which start the audio paths.
@main
enum Launcher {
    static func main() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let running = others.first {
            NSLog("Hertzwise is already running (pid %d); quitting", running.processIdentifier)
            exit(0)
        }
        SampleRateSwitcherApp.main()
    }
}

struct SampleRateSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = SampleRateModel()
    @State private var eq = EQModel()
    private let updates = UpdateChecker.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, eq: eq, updates: updates)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarMark.image)
                if let title = model.menuBarTitle {
                    Text(title)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
