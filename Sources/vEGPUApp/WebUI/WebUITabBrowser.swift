import SwiftUI

struct WebUITabBrowser: View {
    let tabID: String
    let title: String
    let url: URL
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var store = WebViewStore()

    var body: some View {
        StableWebView(store: store, url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.windowBackground(colorScheme))
            .clipped()
            .onReceive(NotificationCenter.default.publisher(for: .vegpuReloadWebTab)) { notification in
                guard notification.userInfo?["tabID"] as? String == tabID else { return }
                store.reload()
            }
    }
}
