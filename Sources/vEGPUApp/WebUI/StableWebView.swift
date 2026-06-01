import SwiftUI
import WebKit

struct StableWebView: NSViewRepresentable {
    let store: WebViewStore
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        store.applyAppearance(isDark: context.environment.colorScheme == .dark)
        store.load(url)
        return store.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        store.applyAppearance(isDark: context.environment.colorScheme == .dark)
        store.load(url)
    }
}
