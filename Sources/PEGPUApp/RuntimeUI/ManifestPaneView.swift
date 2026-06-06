import AppKit
import SwiftUI

struct ManifestPaneView: View {
    @ObservedObject var manifest: RuntimeManifestState

    var body: some View {
        SelectableTextPane(
            text: manifest.manifestSummary,
            font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )
        .frame(
            maxWidth: .infinity,
            minHeight: RuntimePaneSizing.minHeight,
            idealHeight: RuntimePaneSizing.idealHeight,
            maxHeight: RuntimePaneSizing.maxHeight
        )
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
    }
}
