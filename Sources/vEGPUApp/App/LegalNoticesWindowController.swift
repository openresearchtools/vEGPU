import AppKit
import vEGPUCore

@MainActor
final class LegalNoticesWindowController: NSWindowController {
    private enum LegalDocument: Int, CaseIterable {
        case notices
        case licenses

        var title: String {
            switch self {
            case .notices: return "Notices"
            case .licenses: return "Licenses"
            }
        }

        func url(in generatedLegalURL: URL) -> URL {
            switch self {
            case .notices: return generatedLegalURL.appendingPathComponent("NOTICES")
            case .licenses: return generatedLegalURL.appendingPathComponent("LICENSES")
            }
        }
    }

    private let generatedLegalURL: URL
    private var selectedDocument: LegalDocument = .notices

    private lazy var documentSelector: NSSegmentedControl = {
        let selector = NSSegmentedControl(
            labels: LegalDocument.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(documentSelectionChanged)
        )
        selector.selectedSegment = selectedDocument.rawValue
        selector.segmentStyle = .rounded
        return selector
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

    init() {
        let root = AppPaths.discoverRoot()
        self.generatedLegalURL = root.appendingPathComponent("legal/generated", isDirectory: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vEGPU Legal"
        window.minSize = NSSize(width: 620, height: 420)
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showNotices() {
        show(document: .notices)
    }

    func showLicenses() {
        show(document: .licenses)
    }

    private func show(document: LegalDocument) {
        selectedDocument = document
        documentSelector.selectedSegment = document.rawValue
        loadSelectedDocument()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeContentView() -> NSView {
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "vEGPU Legal")
        title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)

        stack.addArrangedSubview(documentSelector)

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
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        loadSelectedDocument()
        return content
    }

    private func loadSelectedDocument() {
        let url = selectedDocument.url(in: generatedLegalURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            documentTextView.string = "\(selectedDocument.title) file not found.\n\nExpected path:\n\(url.path)"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            if data.count > 4 * 1024 * 1024 {
                documentTextView.string = "\(selectedDocument.title)\n\nThis file is larger than 4 MiB.\n\n\(url.path)"
                return
            }
            documentTextView.string = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "\(selectedDocument.title)\n\nCould not decode this file as text.\n\n\(url.path)"
        } catch {
            documentTextView.string = "\(selectedDocument.title)\n\nCould not read file: \(error.localizedDescription)\n\n\(url.path)"
        }
    }

    @objc private func documentSelectionChanged() {
        guard let document = LegalDocument(rawValue: documentSelector.selectedSegment) else { return }
        selectedDocument = document
        loadSelectedDocument()
    }
}
