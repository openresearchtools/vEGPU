import AppKit
import vEGPUCore

@MainActor
final class LegalNoticesWindowController: NSWindowController {
    private let appRoot: URL
    private let generatedLegalURL: URL
    private let appNoticesURL: URL
    private let appSourceURL: URL
    private let displaySourceURL: URL
    private let machineAppURL: URL
    private let machineNoticesURL: URL
    private let machineSourceBundlesURL: URL
    private let machineGuestSourceURL: URL

    init() {
        let root = AppPaths.discoverRoot()
        self.appRoot = root
        self.generatedLegalURL = root.appendingPathComponent("legal/generated", isDirectory: true)
        self.appNoticesURL = generatedLegalURL.appendingPathComponent("NOTICES.md")
        self.appSourceURL = generatedLegalURL.appendingPathComponent("source/vEGPU-app-source.tar.gz")
        self.displaySourceURL = generatedLegalURL.appendingPathComponent("source/display-runtime-source.tar.gz")
        self.machineAppURL = URL(fileURLWithPath: VfioApp.appPath())
        self.machineNoticesURL = machineAppURL.appendingPathComponent("Contents/Resources/ThirdPartyNotices", isDirectory: true)
        self.machineSourceBundlesURL = machineAppURL.appendingPathComponent("Contents/Resources/SourceBundles", isDirectory: true)
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

    func exportVEGPUSources() {
        exportArchives(
            title: "Export vEGPU Source Archives",
            message: "Choose a folder for the vEGPU app and app-side display runtime source archives.",
            sources: [appSourceURL, displaySourceURL]
        )
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

    func revealVEGPUMachineSources() {
        if FileManager.default.fileExists(atPath: machineSourceBundlesURL.path) {
            reveal(machineSourceBundlesURL, fallbackMessage: "vEGPU Machine source bundles were not found inside \(machineAppURL.path).")
        } else {
            revealVEGPUMachineGuestSource()
        }
    }

    func exportVEGPUMachineSources() {
        let sources = sourceArchives(in: machineSourceBundlesURL) + sourceArchives(in: machineGuestSourceURL)
        exportArchives(
            title: "Export vEGPU Machine Source Archives",
            message: "Choose a folder for vEGPU Machine and guest-driver source archives.",
            sources: sources
        )
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

        let subtitle = NSTextField(wrappingLabelWithString: "vEGPU.app keeps its app-side notices here. vEGPU Machine.app carries its own QEMU/VFIO notices and source bundles inside the Machine app. Use Export to copy bundled source archives to a normal folder.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        stack.addArrangedSubview(subtitle)

        let appButtonRow = NSStackView()
        appButtonRow.orientation = .horizontal
        appButtonRow.spacing = 8
        appButtonRow.alignment = .centerY
        appButtonRow.addArrangedSubview(makeButton("Reveal vEGPU Notices", action: #selector(revealVEGPUNoticesAction)))
        appButtonRow.addArrangedSubview(makeButton("Reveal vEGPU Source", action: #selector(revealVEGPUSourceAction)))
        appButtonRow.addArrangedSubview(makeButton("Export vEGPU Sources...", action: #selector(exportVEGPUSourcesAction)))
        stack.addArrangedSubview(appButtonRow)

        let machineButtonRow = NSStackView()
        machineButtonRow.orientation = .horizontal
        machineButtonRow.spacing = 8
        machineButtonRow.alignment = .centerY
        machineButtonRow.addArrangedSubview(makeButton("Open vEGPU Machine", action: #selector(openVEGPUMachineAction)))
        machineButtonRow.addArrangedSubview(makeButton("Reveal Machine Notices", action: #selector(revealVEGPUMachineNoticesAction)))
        machineButtonRow.addArrangedSubview(makeButton("Reveal Machine Sources", action: #selector(revealVEGPUMachineGuestSourceAction)))
        machineButtonRow.addArrangedSubview(makeButton("Export Machine Sources...", action: #selector(exportVEGPUMachineSourcesAction)))
        stack.addArrangedSubview(machineButtonRow)

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
            "Display runtime source archive: \(status(displaySourceURL))",
            "",
            "vEGPU Machine app: \(status(machineAppURL))",
            "vEGPU Machine notices: \(status(machineNoticesURL))",
            "vEGPU Machine source bundles: \(status(machineSourceBundlesURL))",
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

    private func sourceArchives(in directory: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            return name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tgz")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func exportArchives(title: String, message: String, sources: [URL]) {
        let existingSources = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingSources.isEmpty else {
            showMissingAlert(message: "No bundled source archives were found for this section.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var copied: [URL] = []
        do {
            for source in existingSources {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
                copied.append(target)
            }
            NSWorkspace.shared.activateFileViewerSelecting(copied)
        } catch {
            showMissingAlert(message: "Could not export source archives: \(error.localizedDescription)")
        }
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

    @objc private func exportVEGPUSourcesAction() {
        exportVEGPUSources()
    }

    @objc private func openVEGPUMachineAction() {
        openVEGPUMachine()
    }

    @objc private func revealVEGPUMachineNoticesAction() {
        revealVEGPUMachineNotices()
    }

    @objc private func revealVEGPUMachineGuestSourceAction() {
        revealVEGPUMachineSources()
    }

    @objc private func exportVEGPUMachineSourcesAction() {
        exportVEGPUMachineSources()
    }
}
