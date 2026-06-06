import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PEGPUCore

struct FilesTabView: View {
    let model: NativeAppModel
    @StateObject private var store = FilesTabStore()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FilePaneView(store: store, side: .left) {
                    model.repairFileShares()
                    store.reloadAll()
                }
                Divider()
                FilePaneView(store: store, side: .right) {
                    model.repairFileShares()
                    store.reloadAll()
                }
            }
            if !store.transferJobs.isEmpty {
                Divider()
                FileTransferJobsView(
                    jobs: store.transferJobs,
                    cancel: { store.cancelTransferJob($0) },
                    clear: { store.clearFinishedJobs() }
                )
            }
        }
        .background(AppTheme.windowBackground(colorScheme))
        .onAppear {
            let config = model.configStore.load()
            store.configure(macRoot: config.shareRoot, linuxHome: config.linuxHomeMountPath)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { !store.pendingDelete.isEmpty },
                set: { value in if !value { store.pendingDelete.removeAll() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Permanently Delete", role: .destructive) {
                store.confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                store.pendingDelete.removeAll()
            }
        } message: {
            Text("This permanently deletes \(store.pendingDelete.count) item\(store.pendingDelete.count == 1 ? "" : "s"). This does not move files to Trash.")
        }
    }

    private var deleteTitle: String {
        "Permanently delete \(store.pendingDelete.count) item\(store.pendingDelete.count == 1 ? "" : "s")?"
    }
}

private struct FilePaneView: View {
    @ObservedObject var store: FilesTabStore
    let side: FilesPaneSide
    let repairMounts: () -> Void
    @State private var dropTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            List {
                ForEach(store.items(for: side)) { item in
                    let selected = store.selection(for: side).contains(item.id)
                    FileRow(item: item, isSelected: selected)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            AppTheme.cardBackground(colorScheme)
                        )
                        .contextMenu {
                            contextMenu(item: item)
                        }
                        .onDrop(of: FileDropTypes.accepted, isTargeted: nil) { providers in
                            let destination = item.isDirectory && !item.isPackage
                                ? item.url
                                : URL(fileURLWithPath: store.path(for: side))
                            store.acceptDrop(providers, toDirectory: destination)
                            return true
                        }
                        .onTapGesture(count: 2) {
                            store.open(item, side: side)
                        }
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                store.select(item, side: side)
                            }
                        )
                        .onDrag {
                            store.dragProvider(for: item.url)
                        }
                }
            }
            .listStyle(.inset)
            .onDrop(of: FileDropTypes.accepted, isTargeted: $dropTargeted) { providers in
                store.acceptDrop(providers, to: side)
                return true
            }
            .contextMenu {
                Button("Paste Here") { store.pasteInto(side) }
                Button("Refresh") { store.reload(side) }
                Divider()
                Button("Reveal This Folder in Finder") {
                    store.reveal([URL(fileURLWithPath: store.path(for: side))])
                }
            }
            .overlay {
                if store.items(for: side).isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: side == .left ? "macwindow" : "externaldrive")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(store.emptyText(for: side))
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }
            .scrollContentBackground(.hidden)
            .tint(AppTheme.tint(colorScheme))
            .background(dropTargeted ? AppTheme.selectedBackground(colorScheme).opacity(0.22) : AppTheme.cardBackground(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paneHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(side.title)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("Sort", selection: sort) {
                    ForEach(FileSortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                Spacer(minLength: 8)
                Button {
                    repairMounts()
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .help("Repair mounts")
                Button {
                    store.goBack(side)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                Button {
                    store.goForward(side)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Forward")
                Button {
                    store.goUp(side)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Up")
                Button {
                    store.reload(side)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            GeometryReader { proxy in
                let gap: CGFloat = 8
                let width = max(0, proxy.size.width - gap)
                HStack(spacing: gap) {
                    TrailingPathField(text: path) {
                        store.navigate(side, to: store.path(for: side))
                    }
                    .frame(width: width * 0.7)
                    TextField("Search", text: search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: width * 0.3)
                }
            }
            .frame(height: 30)
        }
        .padding(10)
        .background(AppTheme.panelBackground(colorScheme))
    }

    private var selection: Binding<Set<String>> {
        Binding(
            get: { store.selection(for: side) },
            set: { store.setSelection($0, for: side) }
        )
    }

    private var path: Binding<String> {
        Binding(
            get: { store.path(for: side) },
            set: { store.setPath($0, for: side) }
        )
    }

    private var search: Binding<String> {
        Binding(
            get: { store.search(for: side) },
            set: { store.setSearch($0, for: side) }
        )
    }

    private var sort: Binding<FileSortMode> {
        Binding(
            get: { store.sort(for: side) },
            set: { store.setSort($0, for: side) }
        )
    }

    @ViewBuilder
    private func contextMenu(item: FileItem) -> some View {
        Button("Open") { store.open(item, side: side) }
        Button("Reveal in Finder") { store.reveal([item.url]) }
        Button("Paste Here") { store.pasteInto(side) }
        if item.isDirectory && !item.isPackage {
            Button("Paste Into Folder") { store.pasteIntoDirectory(item.url) }
        }
        Divider()
        Button("Copy") { store.copyToPasteboard([item.url]) }
        Button("Move To...") { store.moveWithPicker([item.url], side: side) }
        Divider()
        Button("Rename") { store.rename(item, side: side) }
        Button("Delete", role: .destructive) { store.pendingDelete = [item.url] }
    }
}

private struct FileRow: View {
    let item: FileItem
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .foregroundStyle(isSelected ? AppTheme.selectedForeground(colorScheme) : (item.isDirectory ? AppTheme.tint(colorScheme) : .secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(isSelected ? AppTheme.selectedForeground(colorScheme) : Color.primary)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AppTheme.selectedForeground(colorScheme).opacity(0.75) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AppTheme.selectedBackground(colorScheme) : Color.clear)
        )
    }
}

private enum FileDropTypes {
    static let internalURL = "com.pegpu.file-url"
    static let accepted: [UTType] = [.fileURL, .url, .plainText, UTType(exportedAs: internalURL)]
}

private struct TrailingPathField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.lineBreakMode = .byTruncatingHead
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        field.lineBreakMode = .byTruncatingHead
        field.cell?.lineBreakMode = .byTruncatingHead
        field.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TrailingPathField

        init(parent: TrailingPathField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() else { return }
            let end = field.stringValue.utf16.count
            editor.selectedRange = NSRange(location: end, length: 0)
            editor.scrollRangeToVisible(NSRange(location: end, length: 0))
        }

        @objc func commit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onCommit()
        }
    }
}

private struct FileTransferJobsView: View {
    let jobs: [FileTransferJob]
    let cancel: (UUID) -> Void
    let clear: () -> Void

    private var canClear: Bool {
        jobs.contains { !$0.status.isRunning }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Text("\(jobs.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: clear)
                    .disabled(!canClear)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(jobs) { job in
                        FileTransferJobRow(job: job) {
                            cancel(job.id)
                        }
                    }
                }
            }
            .frame(maxHeight: min(220, CGFloat(max(1, jobs.count)) * 58))
        }
        .padding(12)
    }
}

private struct FileTransferJobRow: View {
    let job: FileTransferJob
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(job.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(job.status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.status.color)
                Spacer()
                if job.status.isRunning {
                    Text(job.speedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Cancel this transfer")
                }
            }
            ProgressView(value: job.fraction)
            Text(job.detail)
                .font(.caption)
                .foregroundStyle(job.status == .failed ? .red : .secondary)
                .lineLimit(1)
        }
    }
}

private enum FilesPaneSide: Sendable {
    case left
    case right

    var title: String {
        switch self {
        case .left: return "Mac"
        case .right: return "VM"
        }
    }
}

private enum FileSortMode: String, CaseIterable, Identifiable, Sendable {
    case name
    case date
    case size
    case kind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

private struct FileItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64
    let modified: Date?

    var icon: String {
        isDirectory ? "folder.fill" : "doc"
    }

    var detail: String {
        let sizeText = isDirectory ? "Folder" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if let modified {
            return "\(sizeText) - \(modified.formatted(date: .abbreviated, time: .shortened))"
        }
        return sizeText
    }
}

private enum FileTransferStatus: Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled

    var isRunning: Bool {
        self == .running
    }

    var label: String {
        switch self {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    var color: Color {
        switch self {
        case .running: return .secondary
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

private struct FileTransferJob: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var detail: String
    var completedBytes: Int64
    var totalBytes: Int64
    var startedAt: Date
    var status: FileTransferStatus
    var finishedAt: Date?

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    var speedText: String {
        let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
        let bytes = Int64(Double(completedBytes) / elapsed)
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))/s"
    }
}

private final class URLDropAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    func values() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
private final class FilesTabStore: ObservableObject {
    @Published private var leftPathValue = NSHomeDirectory()
    @Published private var rightPathValue = defaultLinuxHomeMountPath
    @Published private var leftSearch = ""
    @Published private var rightSearch = ""
    @Published private var leftSort: FileSortMode = .name
    @Published private var rightSort: FileSortMode = .name
    @Published private var leftItems: [FileItem] = []
    @Published private var rightItems: [FileItem] = []
    @Published private var leftLoading = false
    @Published private var rightLoading = false
    @Published private var leftError: String?
    @Published private var rightError: String?
    @Published private var leftSelection = Set<String>()
    @Published private var rightSelection = Set<String>()
    @Published var pendingDelete: [URL] = []
    @Published var transferJobs: [FileTransferJob] = []
    @Published var status = "Direct mounted filesystem operations"

    private var leftBack: [String] = []
    private var rightBack: [String] = []
    private var leftForward: [String] = []
    private var rightForward: [String] = []
    private var leftReloadTask: Task<Void, Never>?
    private var rightReloadTask: Task<Void, Never>?
    private var leftReloadGeneration = 0
    private var rightReloadGeneration = 0
    private var transferTasks: [UUID: Task<Void, Never>] = [:]

    func configure(macRoot: String, linuxHome: String) {
        leftPathValue = normalizeShareRoot(macRoot)
        rightPathValue = normalizeAbsolutePath(linuxHome, fallback: defaultLinuxHomeMountPath)
        reloadAll()
    }

    func items(for side: FilesPaneSide) -> [FileItem] {
        side == .left ? leftItems : rightItems
    }

    func path(for side: FilesPaneSide) -> String {
        side == .left ? leftPathValue : rightPathValue
    }

    func setPath(_ value: String, for side: FilesPaneSide) {
        if side == .left {
            leftPathValue = value
        } else {
            rightPathValue = value
        }
    }

    func search(for side: FilesPaneSide) -> String {
        side == .left ? leftSearch : rightSearch
    }

    func setSearch(_ value: String, for side: FilesPaneSide) {
        if side == .left {
            leftSearch = value
        } else {
            rightSearch = value
        }
        reload(side)
    }

    func sort(for side: FilesPaneSide) -> FileSortMode {
        side == .left ? leftSort : rightSort
    }

    func setSort(_ value: FileSortMode, for side: FilesPaneSide) {
        if side == .left {
            leftSort = value
        } else {
            rightSort = value
        }
        reload(side)
    }

    func selection(for side: FilesPaneSide) -> Set<String> {
        side == .left ? leftSelection : rightSelection
    }

    func setSelection(_ value: Set<String>, for side: FilesPaneSide) {
        if side == .left {
            leftSelection = value
        } else {
            rightSelection = value
        }
    }

    func select(_ item: FileItem, side: FilesPaneSide) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let shouldToggle = flags.contains(.command)
        var next = selection(for: side)
        if shouldToggle {
            if next.contains(item.id) {
                next.remove(item.id)
            } else {
                next.insert(item.id)
            }
        } else {
            next = [item.id]
        }
        setSelection(next, for: side)
    }

    func emptyText(for side: FilesPaneSide) -> String {
        if isLoading(side) {
            return "Loading..."
        }
        if let error = loadError(side) {
            return error
        }
        return "No files"
    }

    func isLoading(_ side: FilesPaneSide) -> Bool {
        side == .left ? leftLoading : rightLoading
    }

    func loadError(_ side: FilesPaneSide) -> String? {
        side == .left ? leftError : rightError
    }

    func reloadAll() {
        reload(.left)
        reload(.right)
    }

    func reload(_ side: FilesPaneSide) {
        let url = URL(fileURLWithPath: path(for: side)).standardizedFileURL
        let query = search(for: side)
        let mode = sort(for: side)
        let generation = nextReloadGeneration(side)
        setLoading(true, for: side)
        setLoadError(nil, for: side)
        setReloadTask(Task { [weak self] in
            do {
                let items = try await FileBrowserWorker.loadItems(at: url, search: query, sort: mode)
                await MainActor.run {
                    self?.finishReload(side, generation: generation, items: items, error: nil)
                }
            } catch {
                await MainActor.run {
                    self?.finishReload(side, generation: generation, items: [], error: firstLine(String(describing: error)))
                }
            }
        }, for: side)
        status = "Mac: \(leftPathValue)    VM: \(rightPathValue)"
    }

    private func finishReload(_ side: FilesPaneSide, generation: Int, items: [FileItem], error: String?) {
        guard generation == reloadGeneration(side) else { return }
        if side == .left {
            leftItems = items
            leftSelection = leftSelection.intersection(Set(items.map(\.id)))
        } else {
            rightItems = items
            rightSelection = rightSelection.intersection(Set(items.map(\.id)))
        }
        setLoading(false, for: side)
        setLoadError(error, for: side)
        status = "Mac: \(leftPathValue)    VM: \(rightPathValue)"
    }

    private func nextReloadGeneration(_ side: FilesPaneSide) -> Int {
        if side == .left {
            leftReloadGeneration += 1
            return leftReloadGeneration
        }
        rightReloadGeneration += 1
        return rightReloadGeneration
    }

    private func reloadGeneration(_ side: FilesPaneSide) -> Int {
        side == .left ? leftReloadGeneration : rightReloadGeneration
    }

    private func setReloadTask(_ task: Task<Void, Never>, for side: FilesPaneSide) {
        if side == .left {
            leftReloadTask?.cancel()
            leftReloadTask = task
        } else {
            rightReloadTask?.cancel()
            rightReloadTask = task
        }
    }

    private func setLoading(_ loading: Bool, for side: FilesPaneSide) {
        if side == .left {
            leftLoading = loading
        } else {
            rightLoading = loading
        }
    }

    private func setLoadError(_ error: String?, for side: FilesPaneSide) {
        if side == .left {
            leftError = error
        } else {
            rightError = error
        }
    }

    func navigate(_ side: FilesPaneSide, to rawPath: String) {
        let path = normalizeAbsolutePath(rawPath, fallback: side == .left ? NSHomeDirectory() : defaultLinuxHomeMountPath)
        pushHistory(side)
        setPath(path, for: side)
        clearForward(side)
        reload(side)
    }

    func goUp(_ side: FilesPaneSide) {
        let parent = URL(fileURLWithPath: path(for: side)).deletingLastPathComponent().path
        navigate(side, to: parent.isEmpty ? "/" : parent)
    }

    func goBack(_ side: FilesPaneSide) {
        guard let path = popBack(side) else { return }
        pushForward(side)
        setPath(path, for: side)
        reload(side)
    }

    func goForward(_ side: FilesPaneSide) {
        guard let path = popForward(side) else { return }
        pushHistory(side)
        setPath(path, for: side)
        reload(side)
    }

    func open(_ item: FileItem, side: FilesPaneSide) {
        if item.isDirectory && !item.isPackage {
            navigate(side, to: item.url.path)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection(_ side: FilesPaneSide) {
        selectedURLs(side).forEach { NSWorkspace.shared.open($0) }
    }

    func revealSelection(_ side: FilesPaneSide) {
        reveal(selectedURLs(side))
    }

    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copySelectionToPasteboard(_ side: FilesPaneSide) {
        copyToPasteboard(selectedURLs(side))
    }

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    func dragProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        if let data = url.absoluteString.data(using: .utf8) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: FileDropTypes.internalURL, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    func pasteInto(_ side: FilesPaneSide) {
        let urls = pasteboardFileURLs()
        guard !urls.isEmpty else {
            status = "Pasteboard does not contain file URLs"
            return
        }
        copy(urls, to: URL(fileURLWithPath: path(for: side)), deleteSource: false)
    }

    func pasteIntoDirectory(_ directory: URL) {
        let urls = pasteboardFileURLs()
        guard !urls.isEmpty else {
            status = "Pasteboard does not contain file URLs"
            return
        }
        copy(urls, to: directory, deleteSource: false)
    }

    func moveSelectionWithPicker(_ side: FilesPaneSide) {
        moveWithPicker(selectedURLs(side), side: side)
    }

    func moveWithPicker(_ urls: [URL], side: FilesPaneSide) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path(for: side))
        panel.prompt = "Move Here"
        panel.message = "Choose a destination folder."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        move(urls, to: destination)
    }

    func requestDeleteSelection(_ side: FilesPaneSide) {
        pendingDelete = selectedURLs(side)
    }

    func confirmDelete() {
        let urls = pendingDelete
        pendingDelete.removeAll()
        delete(urls)
    }

    func rename(_ item: FileItem, side: FilesPaneSide) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = item.url.path
        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let nextName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextName.isEmpty, nextName != item.name else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(nextName)
        let id = appendTransferJob(title: "Renaming 1 item", detail: destination.path)
        transferTasks[id] = Task { [weak self] in
            do {
                try await FileOperationWorker.rename(item.url, to: destination) { update in
                    Task { @MainActor in
                        self?.updateTransferJob(id, update: update)
                    }
                }
                await MainActor.run {
                    self?.finishTransferJob(id, status: .completed, detail: "Completed")
                    self?.reload(side)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .cancelled, detail: "Cancelled")
                    self?.reload(side)
                }
            } catch {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .failed, detail: firstLine(String(describing: error)))
                    self?.reload(side)
                }
            }
        }
    }

    func acceptDrop(_ providers: [NSItemProvider], to side: FilesPaneSide) {
        acceptDrop(providers, toDirectory: URL(fileURLWithPath: path(for: side)))
    }

    func acceptDrop(_ providers: [NSItemProvider], toDirectory destination: URL) {
        let accumulator = URLDropAccumulator()
        let group = DispatchGroup()
        for provider in providers {
            let type = FileDropTypes.accepted
                .map(\.identifier)
                .first { provider.hasItemConformingToTypeIdentifier($0) }
            guard let type else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    accumulator.append(url)
                } else if let string = item as? String, let url = URL(string: string) {
                    accumulator.append(url)
                } else if let url = item as? NSURL {
                    accumulator.append(url as URL)
                } else if let url = item as? URL {
                    accumulator.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            self.copy(accumulator.values(), to: destination, deleteSource: false)
        }
    }

    func copy(_ urls: [URL], to destination: URL, deleteSource: Bool) {
        guard !urls.isEmpty else { return }
        let id = appendTransferJob(
            title: transferTitle(deleteSource ? "Moving" : "Copying", count: urls.count),
            detail: destination.path
        )
        transferTasks[id] = Task { [weak self] in
            do {
                try await FileOperationWorker.copy(urls, to: destination, deleteSource: deleteSource) { update in
                    Task { @MainActor in
                        self?.updateTransferJob(id, update: update)
                    }
                }
                await MainActor.run {
                    self?.finishTransferJob(id, status: .completed, detail: "Completed")
                    self?.reloadAll()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .cancelled, detail: "Cancelled")
                    self?.reloadAll()
                }
            } catch {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .failed, detail: firstLine(String(describing: error)))
                    self?.reloadAll()
                }
            }
        }
    }

    func move(_ urls: [URL], to destination: URL) {
        guard !urls.isEmpty else { return }
        let id = appendTransferJob(
            title: transferTitle("Moving", count: urls.count),
            detail: destination.path
        )
        transferTasks[id] = Task { [weak self] in
            do {
                try await FileOperationWorker.move(urls, to: destination) { update in
                    Task { @MainActor in
                        self?.updateTransferJob(id, update: update)
                    }
                }
                await MainActor.run {
                    self?.finishTransferJob(id, status: .completed, detail: "Completed")
                    self?.reloadAll()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .cancelled, detail: "Cancelled")
                    self?.reloadAll()
                }
            } catch {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .failed, detail: firstLine(String(describing: error)))
                    self?.reloadAll()
                }
            }
        }
    }

    func delete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let id = appendTransferJob(
            title: transferTitle("Deleting", count: urls.count),
            detail: "Preparing..."
        )
        transferTasks[id] = Task { [weak self] in
            do {
                try await FileOperationWorker.delete(urls) { update in
                    Task { @MainActor in
                        self?.updateTransferJob(id, update: update)
                    }
                }
                await MainActor.run {
                    self?.finishTransferJob(id, status: .completed, detail: "Completed")
                    self?.reloadAll()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .cancelled, detail: "Cancelled")
                    self?.reloadAll()
                }
            } catch {
                await MainActor.run {
                    self?.finishTransferJob(id, status: .failed, detail: firstLine(String(describing: error)))
                    self?.reloadAll()
                }
            }
        }
    }

    func cancelTransferJob(_ id: UUID) {
        transferTasks[id]?.cancel()
        status = "Transfer cancellation requested"
    }

    func clearFinishedJobs() {
        transferJobs.removeAll { job in
            if job.status.isRunning { return false }
            transferTasks[job.id] = nil
            return true
        }
    }

    private func appendTransferJob(title: String, detail: String) -> UUID {
        let id = UUID()
        transferJobs.append(FileTransferJob(
            id: id,
            title: title,
            detail: detail,
            completedBytes: 0,
            totalBytes: 0,
            startedAt: Date(),
            status: .running,
            finishedAt: nil
        ))
        return id
    }

    private func updateTransferJob(_ id: UUID, update: FileCopyUpdate) {
        guard let index = transferJobs.firstIndex(where: { $0.id == id }) else { return }
        transferJobs[index].detail = update.detail
        transferJobs[index].completedBytes = update.completedBytes
        transferJobs[index].totalBytes = update.totalBytes
    }

    private func finishTransferJob(_ id: UUID, status: FileTransferStatus, detail: String) {
        guard let index = transferJobs.firstIndex(where: { $0.id == id }) else { return }
        transferJobs[index].status = status
        transferJobs[index].detail = detail
        transferJobs[index].finishedAt = Date()
        transferTasks[id] = nil
    }

    private func transferTitle(_ action: String, count: Int) -> String {
        "\(action) \(count) item\(count == 1 ? "" : "s")"
    }

    private func selectedURLs(_ side: FilesPaneSide) -> [URL] {
        let selected = selection(for: side)
        return items(for: side).filter { selected.contains($0.id) }.map(\.url)
    }

    private func pasteboardFileURLs() -> [URL] {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
            return urls.map { $0 as URL }.filter { $0.isFileURL }
        }
        let strings = NSPasteboard.general.string(forType: .fileURL)
            ?? NSPasteboard.general.string(forType: .URL)
            ?? NSPasteboard.general.string(forType: .string)
            ?? ""
        return strings
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: String($0)) }
            .filter { $0.isFileURL }
    }

    private func pushHistory(_ side: FilesPaneSide) {
        if side == .left {
            leftBack.append(leftPathValue)
        } else {
            rightBack.append(rightPathValue)
        }
    }

    private func pushForward(_ side: FilesPaneSide) {
        if side == .left {
            leftForward.append(leftPathValue)
        } else {
            rightForward.append(rightPathValue)
        }
    }

    private func popBack(_ side: FilesPaneSide) -> String? {
        side == .left ? leftBack.popLast() : rightBack.popLast()
    }

    private func popForward(_ side: FilesPaneSide) -> String? {
        side == .left ? leftForward.popLast() : rightForward.popLast()
    }

    private func clearForward(_ side: FilesPaneSide) {
        if side == .left {
            leftForward.removeAll()
        } else {
            rightForward.removeAll()
        }
    }
}

private enum FileBrowserWorker {
    static func loadItems(at url: URL, search: String, sort: FileSortMode) async throws -> [FileItem] {
        try await Task.detached(priority: .utility) {
            try loadItemsSync(at: url, search: search, sort: sort)
        }.value
    }

    private static func loadItemsSync(at url: URL, search: String, sort: FileSortMode) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants])
        let filtered = urls.filter { candidate in
            guard !search.isEmpty else { return true }
            return candidate.lastPathComponent.localizedCaseInsensitiveContains(search)
        }
        return filtered.compactMap { candidate in
            let values = try? candidate.resourceValues(forKeys: Set(keys))
            return FileItem(
                id: candidate.path,
                url: candidate,
                name: candidate.lastPathComponent,
                isDirectory: values?.isDirectory == true,
                isPackage: values?.isPackage == true,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            switch sort {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date:
                return (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast)
            case .size:
                return lhs.size > rhs.size
            case .kind:
                return lhs.url.pathExtension.localizedStandardCompare(rhs.url.pathExtension) == .orderedAscending
            }
        }
    }
}

private struct FileCopyUpdate: Sendable {
    let detail: String
    let completedBytes: Int64
    let totalBytes: Int64
}

private enum FileOperationWorker {
    static func copy(_ urls: [URL], to destination: URL, deleteSource: Bool, progress: @escaping @Sendable (FileCopyUpdate) -> Void) async throws {
        try await Task.detached(priority: .utility) {
            let total = try urls.reduce(Int64(0)) { try $0 + totalBytes($1) }
            var completed: Int64 = 0
            for url in urls {
                try Task.checkCancellation()
                let target = uniqueDestination(for: url, in: destination)
                try copyItem(url, to: target, completed: &completed, total: total, progress: progress)
                if deleteSource {
                    try Task.checkCancellation()
                    try FileManager.default.removeItem(at: url)
                }
            }
        }.value
    }

    static func move(_ urls: [URL], to destination: URL, progress: @escaping @Sendable (FileCopyUpdate) -> Void) async throws {
        try await Task.detached(priority: .utility) {
            let total = try urls.reduce(Int64(0)) { try $0 + totalBytes($1) }
            var completed: Int64 = 0
            for url in urls {
                try Task.checkCancellation()
                let target = uniqueDestination(for: url, in: destination)
                if sameVolume(url, destination) {
                    let bytes = try totalBytes(url)
                    progress(FileCopyUpdate(detail: url.path, completedBytes: completed, totalBytes: total))
                    try FileManager.default.moveItem(at: url, to: target)
                    completed += max(1, bytes)
                    progress(FileCopyUpdate(detail: target.path, completedBytes: completed, totalBytes: total))
                } else {
                    try copyItem(url, to: target, completed: &completed, total: total, progress: progress)
                    try Task.checkCancellation()
                    try FileManager.default.removeItem(at: url)
                }
            }
        }.value
    }

    static func delete(_ urls: [URL], progress: @escaping @Sendable (FileCopyUpdate) -> Void) async throws {
        try await Task.detached(priority: .utility) {
            let total = Int64(max(1, urls.count))
            var completed: Int64 = 0
            for url in urls {
                try Task.checkCancellation()
                progress(FileCopyUpdate(detail: url.path, completedBytes: completed, totalBytes: total))
                try FileManager.default.removeItem(at: url)
                completed += 1
                progress(FileCopyUpdate(detail: url.path, completedBytes: completed, totalBytes: total))
            }
        }.value
    }

    static func rename(_ source: URL, to destination: URL, progress: @escaping @Sendable (FileCopyUpdate) -> Void) async throws {
        try await Task.detached(priority: .utility) {
            progress(FileCopyUpdate(detail: source.path, completedBytes: 0, totalBytes: 1))
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: source, to: destination)
            progress(FileCopyUpdate(detail: destination.path, completedBytes: 1, totalBytes: 1))
        }.value
    }

    static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(source.lastPathComponent)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = source.pathExtension
        let stem = ext.isEmpty ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent.replacingOccurrences(of: ".\(ext)$", with: "", options: .regularExpression)
        for index in 1..<10_000 {
            let name = ext.isEmpty ? "\(stem) copy \(index)" : "\(stem) copy \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(source.lastPathComponent).\(UUID().uuidString)")
    }

    static func sameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let left, let right else { return false }
        return "\(left)" == "\(right)"
    }

    private static func copyItem(_ source: URL, to destination: URL, completed: inout Int64, total: Int64, progress: @escaping @Sendable (FileCopyUpdate) -> Void) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        if isDir.boolValue {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])
            for child in children {
                try Task.checkCancellation()
                try copyItem(child, to: destination.appendingPathComponent(child.lastPathComponent), completed: &completed, total: total, progress: progress)
            }
            return
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent().appendingPathComponent("\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        guard let input = InputStream(url: source), let output = OutputStream(url: partial, append: false) else {
            throw RuntimeError.message("Could not open file streams for \(source.path)")
        }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }
        let bufferSize = 4 * 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while input.hasBytesAvailable {
            try Task.checkCancellation()
            let read = input.read(buffer, maxLength: bufferSize)
            if read < 0 { throw input.streamError ?? RuntimeError.message("Read failed: \(source.path)") }
            if read == 0 { break }
            var written = 0
            while written < read {
                let count = output.write(buffer.advanced(by: written), maxLength: read - written)
                if count <= 0 { throw output.streamError ?? RuntimeError.message("Write failed: \(partial.path)") }
                written += count
            }
            completed += Int64(read)
            progress(FileCopyUpdate(detail: source.path, completedBytes: completed, totalBytes: total))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private static func totalBytes(_ url: URL) throws -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: nil) {
            for case let child as URL in enumerator {
                let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values?.isDirectory != true {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return total
    }
}
