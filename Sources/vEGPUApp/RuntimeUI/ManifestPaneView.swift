import SwiftUI

struct ManifestPaneView: View {
    @ObservedObject var manifest: RuntimeManifestState

    var body: some View {
        ScrollView {
            Text(manifest.manifestSummary)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
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
