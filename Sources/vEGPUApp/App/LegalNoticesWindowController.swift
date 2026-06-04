import AppKit
import vEGPUCore

@MainActor
final class LegalNoticesWindowController: NSWindowController {
    private struct NoticeDocument {
        var title: String
        var url: URL
    }

    private let appRoot: URL
    private let generatedLegalURL: URL
    private let appNoticesURL: URL
    private let appLicenseURL: URL
    private let appManifestURL: URL
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
        self.appNoticesURL = generatedLegalURL.appendingPathComponent("NOTICES")
        self.appLicenseURL = generatedLegalURL.appendingPathComponent("LICENSES")
        self.appManifestURL = generatedLegalURL.appendingPathComponent("manifest.json")
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

    private var documents: [NoticeDocument] = []

    func revealVEGPUNotices() {
        revealVEGPULegalFiles()
    }

    func revealVEGPULegalFiles() {
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
        revealVEGPUMachineLegalFiles()
    }

    func revealVEGPUMachineLegalFiles() {
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

    private lazy var documentPopUp: NSPopUpButton = {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(documentSelectionChanged)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return popup
    }()

    private lazy var documentTextView: NSTextView = {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        return textView
    }()

    private lazy var statusLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        return label
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

        let subtitle = NSTextField(wrappingLabelWithString: "vEGPU.app carries consolidated app-side notices, licenses, and source archives. vEGPU Machine.app carries separate QEMU/VFIO/DriverKit notices and source bundles. Select Notices or Licenses below, or export source archives to a normal folder.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 3
        stack.addArrangedSubview(subtitle)

        let appButtonRow = NSStackView()
        appButtonRow.orientation = .horizontal
        appButtonRow.spacing = 8
        appButtonRow.alignment = .centerY
        appButtonRow.addArrangedSubview(makeButton("Reveal vEGPU Legal Files", action: #selector(revealVEGPULegalFilesAction)))
        appButtonRow.addArrangedSubview(makeButton("Export vEGPU Sources...", action: #selector(exportVEGPUSourcesAction)))
        stack.addArrangedSubview(appButtonRow)

        let machineButtonRow = NSStackView()
        machineButtonRow.orientation = .horizontal
        machineButtonRow.spacing = 8
        machineButtonRow.alignment = .centerY
        machineButtonRow.addArrangedSubview(makeButton("Reveal Machine Legal Files", action: #selector(revealVEGPUMachineLegalFilesAction)))
        machineButtonRow.addArrangedSubview(makeButton("Export Machine Sources...", action: #selector(exportVEGPUMachineSourcesAction)))
        stack.addArrangedSubview(machineButtonRow)

        let documentRow = NSStackView()
        documentRow.orientation = .horizontal
        documentRow.spacing = 8
        documentRow.alignment = .centerY
        documentRow.addArrangedSubview(documentPopUp)
        documentRow.addArrangedSubview(makeButton("Open Selected", action: #selector(openSelectedNoticeAction)))
        documentRow.addArrangedSubview(makeButton("Reveal Selected", action: #selector(revealSelectedNoticeAction)))
        stack.addArrangedSubview(documentRow)

        stack.addArrangedSubview(statusLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = documentTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            documentRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            documentPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        refreshDocumentList()
        return content
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func refreshSummary() {
        refreshDocumentList()
    }

    private func status(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path) ? "present - \(url.path)" : "missing - \(url.path)"
    }

    private func refreshDocumentList() {
        var next: [NoticeDocument] = []
        appendIfExists(title: "Notices", url: appNoticesURL, into: &next)
        appendIfExists(title: "Licenses", url: appLicenseURL, into: &next)

        documents = dedupe(next).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        documentPopUp.removeAllItems()
        if documents.isEmpty {
            documentPopUp.addItem(withTitle: "No notices found")
            documentPopUp.isEnabled = false
        } else {
            documents.forEach { documentPopUp.addItem(withTitle: $0.title) }
            documentPopUp.isEnabled = true
        }
        statusLabel.stringValue = [
            "vEGPU notices: \(status(appNoticesURL))",
            "vEGPU licenses: \(status(appLicenseURL))",
            "Machine legal files: \(status(machineNoticesURL))",
            "Source archives: \(status(appSourceURL)); \(status(displaySourceURL)); \(status(machineSourceBundlesURL))"
        ].joined(separator: "\n")
        loadSelectedDocument()
    }

    private func appendIfExists(title: String, url: URL, into documents: inout [NoticeDocument]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        documents.append(NoticeDocument(title: title, url: url))
    }

    private func dedupe(_ entries: [NoticeDocument]) -> [NoticeDocument] {
        var seen = Set<String>()
        var result: [NoticeDocument] = []
        for entry in entries {
            guard seen.insert(entry.url.path).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    private func selectedDocument() -> NoticeDocument? {
        let index = documentPopUp.indexOfSelectedItem
        guard documents.indices.contains(index) else { return nil }
        return documents[index]
    }

    private func loadSelectedDocument() {
        guard let document = selectedDocument() else {
            documentTextView.string = [
                "No license or notice documents were found.",
                "",
                "vEGPU app root: \(appRoot.path)",
                "Generated notices: \(status(appNoticesURL))",
                "Generated licenses: \(status(appLicenseURL))",
                "Generated manifest: \(status(appManifestURL))",
                "vEGPU source archive: \(status(appSourceURL))",
                "Display runtime source archive: \(status(displaySourceURL))",
                "vEGPU Machine notices: \(status(machineNoticesURL))",
                "vEGPU Machine source bundles: \(status(machineSourceBundlesURL))",
                "vEGPU Machine guest/source bundles: \(status(machineGuestSourceURL))"
            ].joined(separator: "\n")
            return
        }
        do {
            let data = try Data(contentsOf: document.url)
            if data.count > 4 * 1024 * 1024 {
                documentTextView.string = "\(document.title)\n\nThis notice file is larger than 4 MiB. Use Open Selected or Reveal Selected to inspect it in Finder.\n\n\(document.url.path)"
                return
            }
            documentTextView.string = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "\(document.title)\n\nCould not decode this file as text.\n\n\(document.url.path)"
        } catch {
            documentTextView.string = "\(document.title)\n\nCould not read notice file: \(error.localizedDescription)\n\n\(document.url.path)"
        }
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

    @objc private func revealVEGPULegalFilesAction() {
        revealVEGPULegalFiles()
    }

    @objc private func exportVEGPUSourcesAction() {
        exportVEGPUSources()
    }

    @objc private func revealVEGPUMachineLegalFilesAction() {
        revealVEGPUMachineLegalFiles()
    }

    @objc private func exportVEGPUMachineSourcesAction() {
        exportVEGPUMachineSources()
    }

    @objc private func documentSelectionChanged() {
        loadSelectedDocument()
    }

    @objc private func openSelectedNoticeAction() {
        guard let document = selectedDocument() else {
            showMissingAlert(message: "No notice file is selected.")
            return
        }
        NSWorkspace.shared.open(document.url)
    }

    @objc private func revealSelectedNoticeAction() {
        guard let document = selectedDocument() else {
            showMissingAlert(message: "No notice file is selected.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }
}
