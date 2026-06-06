import AppKit
import SwiftUI

struct SelectableTextPane: NSViewRepresentable {
    var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var textColor: NSColor = .textColor
    var backgroundColor: NSColor = .textBackgroundColor
    var inset = NSSize(width: 14, height: 14)
    var autoScrollToBottom = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.lastText = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        scrollView.backgroundColor = backgroundColor
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = backgroundColor
        textView.textContainerInset = inset

        guard context.coordinator.lastText != text else { return }
        let hadSelection = textView.selectedRange().length > 0
        textView.string = text
        context.coordinator.lastText = text
        if autoScrollToBottom && !hadSelection {
            let end = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastText = ""
    }
}
