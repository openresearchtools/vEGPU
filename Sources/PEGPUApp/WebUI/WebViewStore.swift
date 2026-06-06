import Foundation
import AppKit
import WebKit

@MainActor
final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    private var targetURL: URL?
    private var retryTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.initialBackgroundScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        self.webView.wantsLayer = true
        applyAppearance(isDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if self.webView.responds(to: Selector(("setDrawsBackground:"))) {
            self.webView.setValue(false, forKey: "drawsBackground")
        }
        self.webView.allowsMagnification = true
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    deinit {
        retryTask?.cancel()
    }

    func load(_ url: URL) {
        let next = url.absoluteString
        guard targetURL?.absoluteString != next else { return }
        targetURL = url
        loadTarget()
    }

    func reload() {
        guard webView.url != nil else {
            loadTarget()
            return
        }
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryTask?.cancel()
        retryTask = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scheduleRetry()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scheduleRetry()
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func loadTarget() {
        guard let targetURL else { return }
        let request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        webView.load(request)
    }

    func applyAppearance(isDark: Bool) {
        let background = isDark
            ? NSColor(red: 0.055, green: 0.051, blue: 0.047, alpha: 1)
            : NSColor.windowBackgroundColor
        webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        webView.wantsLayer = true
        webView.layer?.backgroundColor = background.cgColor
        applyBackground(background, to: webView)
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = background
        }
    }

    private func applyBackground(_ background: NSColor, to view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = true
            scrollView.backgroundColor = background
        }
        view.subviews.forEach { applyBackground(background, to: $0) }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.loadTarget()
            }
        }
    }

    private static let initialBackgroundScript = """
    (() => {
        const style = document.createElement('style');
        style.textContent = `
            html, body { min-height: 100%; color-scheme: light dark; background: Canvas; }
            @media (prefers-color-scheme: dark) {
                html, body { background: #0e0d0c !important; }
            }
            @media (prefers-color-scheme: light) {
                html, body { background: #ffffff !important; }
            }
        `;
        document.documentElement.appendChild(style);
    })();
    """
}
