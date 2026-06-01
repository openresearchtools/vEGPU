import AppKit
import vEGPUCore

@MainActor
final class LegalNoticesWindowController: NSWindowController {
    private let appRoot: URL
    private let generatedLegalURL: URL
    private let appNoticesURL: URL
    private let appSourceURL: URL
    private let machineAppURL: URL
    private let machineNoticesURL: URL
    private let machineGuestSourceURL: URL

    init() {
        let root = AppPaths.discoverRoot()
        self.appRoot = root
        self.generatedLegalURL = root.appendingPathComponent("legal/generated", isDirectory: true)
        self.appNoticesURL = generatedLegalURL.appendingPathComponent("NOTICES.md")
        self.appSourceURL = generatedLegalURL.appendingPathComponent("source/vEGPU-app-source.tar.gz")
        self.machineAppURL = URL(fileURLWithPath: VfioApp.appPath())
        self.machineNoticesURL = machineAppURL.appendingPathComponent("Contents/Resources/ThirdPartyNotices", isDirectory: true)
        self.machineGuestSourceURL = machineAppURL.appendingPathComponent("Contents/Resources/guest-tools/source", isDirectory: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vEGPU Licenses and Notices"
        window.minSize = NSSize(width: 620, height: 420)
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        refreshSummary()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func revealVEGPUNotices() {
        reveal(generatedLegalURL, fallbackMessage: "The generated vEGPU notices have not been built yet.")
    }

    func revealVEGPUSource() {
        reveal(appSourceURL, fallbackMessage: "The vEGPU app source archive has not been generated yet.")
    }

    func openVEGPUMachine() {
        open(machineAppURL, fallbackMessage: "vEGPU Machine.app is not installed at \(machineAppURL.path).")
    }

    func revealVEGPUMachineNotices() {
        reveal(machineNoticesURL, fallbackMessage: "vEGPU Machine notices were not found inside \(machineAppURL.path).")
    }

    func revealVEGPUMachineGuestSource() {
        reveal(machineGuestSourceURL, fallbackMessage: "vEGPU Machine guest source archives were not found inside \(machineAppURL.path).")
    }

    private lazy var summaryTextView: NSTextView = {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        return textView
    }()

    private func makeContentView() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "vEGPU Licenses and Notices")
        title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "vEGPU.app keeps its app-side notices here. vEGPU Machine.app carries its own QEMU/VFIO notices and source bundles inside the Machine app.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        stack.addArrangedSubview(subtitle)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.addArrangedSubview(makeButton("Reveal vEGPU Notices", action: #selector(revealVEGPUNoticesAction)))
        buttonRow.addArrangedSubview(makeButton("Reveal vEGPU Source", action: #selector(revealVEGPUSourceAction)))
        buttonRow.addArrangedSubview(makeButton("Open vEGPU Machine", action: #selector(openVEGPUMachineAction)))
        buttonRow.addArrangedSubview(makeButton("Reveal Machine Notices", action: #selector(revealVEGPUMachineNoticesAction)))
        stack.addArrangedSubview(buttonRow)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = summaryTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        refreshSummary()
        return content
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func refreshSummary() {
        summaryTextView.string = [
            "vEGPU app root: \(appRoot.path)",
            "Generated notices: \(status(appNoticesURL))",
            "vEGPU source archive: \(status(appSourceURL))",
            "",
            "vEGPU Machine app: \(status(machineAppURL))",
            "vEGPU Machine notices: \(status(machineNoticesURL))",
            "vEGPU Machine guest/source bundles: \(status(machineGuestSourceURL))",
            "",
            "The generated vEGPU notice bundle is produced by scripts/build-legal-bundle.sh.",
            "Release builds should set VEGPU_REQUIRE_FULL_SOURCE=1 so generated display-runtime source cannot be skipped."
        ].joined(separator: "\n")
    }

    private func status(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path) ? "present - \(url.path)" : "missing - \(url.path)"
    }

    private func reveal(_ url: URL, fallbackMessage: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showMissingAlert(message: fallbackMessage)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func open(_ url: URL, fallbackMessage: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showMissingAlert(message: fallbackMessage)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showMissingAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File not found"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func revealVEGPUNoticesAction() {
        revealVEGPUNotices()
    }

    @objc private func revealVEGPUSourceAction() {
        revealVEGPUSource()
    }

    @objc private func openVEGPUMachineAction() {
        openVEGPUMachine()
    }

    @objc private func revealVEGPUMachineNoticesAction() {
        revealVEGPUMachineNotices()
    }
}
