import AppKit
import DBCore
import QueryEditor
import SwiftUI

/// Monospaced NSTextView with regex-based syntax highlighting. Deliberately
/// simple: whole-document rehighlight on change is fine at query sizes.
/// Swappable for a tree-sitter implementation behind the same interface later.
struct SyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    let language: DriverDescriptor.QueryLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, highlighter: RegexHighlighter(language: language))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let highlighter: RegexHighlighter
        weak var textView: NSTextView?

        init(text: Binding<String>, highlighter: RegexHighlighter) {
            self.text = text
            self.highlighter = highlighter
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            highlight()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            highlighter.highlight(storage)
        }
    }
}
