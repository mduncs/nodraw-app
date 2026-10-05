import AppKit
import SubjectIsolation
import ImageIO

// MARK: - AppKit Demo Application

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var highlightView: SubjectHighlightView!
    var statusLabel: NSTextField!
    let isolator = SubjectIsolator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let imagePath: String
        if args.count >= 2 {
            imagePath = args[1]
        } else {
            // Default test image
            imagePath = NSString(string: "~/Documents/Screenshots/Screenshot 2026-02-09 at 14.19.16.png")
                .expandingTildeInPath
        }

        guard let imageSource = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: imagePath) as CFURL, nil
        ), let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("Error: Could not load image at \(imagePath)")
            NSApp.terminate(nil)
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        // Size window to image aspect ratio, max 800pt wide
        let aspect = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        let viewWidth: CGFloat = min(800, CGFloat(cgImage.width))
        let viewHeight = viewWidth * aspect
        let windowSize = NSSize(width: viewWidth, height: viewHeight + 40) // +40 for status bar

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Subject Isolation Demo"
        window.center()

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))

        // Status label at bottom
        statusLabel = NSTextField(labelWithString: "Loading...")
        statusLabel.frame = NSRect(x: 8, y: 8, width: windowSize.width - 16, height: 24)
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.autoresizingMask = [.width]
        contentView.addSubview(statusLabel)

        // Subject highlight view fills the rest
        highlightView = SubjectHighlightView(
            frame: NSRect(x: 0, y: 40, width: viewWidth, height: viewHeight)
        )
        highlightView.autoresizingMask = [.width, .height]
        highlightView.image = nsImage
        contentView.addSubview(highlightView)

        // Click handler: toggle individual subjects, or glow all on background click
        highlightView.onSubjectTapped = { [weak self] index in
            guard let self else { return }
            if let idx = index {
                // Toggle this subject
                var current = self.highlightView.highlightedSubjects
                if current.contains(idx) {
                    current.remove(idx)
                } else {
                    current.insert(idx)
                }
                if current.isEmpty {
                    self.highlightView.endGlow(animated: true)
                    self.statusLabel.stringValue = "Click a subject to highlight, or click background to glow all"
                } else {
                    self.highlightView.highlightedSubjects = current
                    self.statusLabel.stringValue = "Highlighting: \(current.sorted())"
                }
            } else {
                // Background click — toggle glow-all
                let allIndices = self.highlightView.isolationResult.map {
                    IndexSet($0.subjects.map(\.index))
                } ?? IndexSet()
                if self.highlightView.highlightedSubjects == allIndices {
                    // Already glowing all → stop
                    self.highlightView.endGlow(animated: true)
                    self.statusLabel.stringValue = "Click a subject to highlight, or click background to glow all"
                } else {
                    // Nothing or partial → glow all
                    self.glowAll()
                }
            }
        }

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        // Run isolation
        Task {
            await runIsolation(cgImage: cgImage)
        }
    }

    @MainActor
    func runIsolation(cgImage: CGImage) async {
        let start = CFAbsoluteTimeGetCurrent()
        statusLabel.stringValue = "Running subject isolation..."

        do {
            let result = try await isolator.isolate(image: cgImage, options: .default)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            highlightView.isolationResult = result
            let types = isolator.availableTypes.map { "\($0)" }.sorted().joined(separator: ", ")

            if result.hasSubjects {
                statusLabel.stringValue = String(
                    format: "%d subject(s) found in %.2fs — click to highlight [%@]",
                    result.subjectCount, elapsed, types
                )
                // Auto-glow all subjects
                glowAll()
            } else {
                statusLabel.stringValue = String(
                    format: "No subjects found (%.2fs) [%@]",
                    elapsed, types
                )
            }
        } catch {
            statusLabel.stringValue = "Error: \(error.localizedDescription)"
        }
    }

    func glowAll() {
        guard let result = highlightView.isolationResult else { return }
        let allIndices = IndexSet(result.subjects.map(\.index))
        highlightView.beginGlow(for: allIndices, animated: true)
        statusLabel.stringValue = "Glowing \(result.subjectCount) subject(s) — click subject to toggle, background to stop"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// Launch
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
