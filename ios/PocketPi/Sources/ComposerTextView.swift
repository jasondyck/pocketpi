import SwiftUI
import UIKit

/// The chat's message box, a UITextView rather than SwiftUI's TextField so
/// the system's own Paste can carry a picture: pasting a copied screenshot
/// attaches it, the same way pasting text inserts text. SwiftUI's
/// `onPasteCommand` is macOS only, and a TextField drops image paste.
///
/// Grows with the text up to eight lines, then scrolls inside, like the
/// `lineLimit(1...8)` it replaces.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    /// The keyboard: set true to focus (a draft, a slash pick), false to
    /// let it go. UIKit reports back when the person taps in or away.
    @Binding var focused: Bool
    /// A pasted picture, before downscaling.
    let onImage: (UIImage) -> Void

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
        view.delegate = context.coordinator
        view.onImagePaste = onImage
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = false
        view.autocapitalizationType = .sentences
        view.keyboardDismissMode = .interactive
        view.text = text
        view.accessibilityIdentifier = "composer"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        context.coordinator.parent = self
        view.onImagePaste = onImage
        if view.text != text {
            view.text = text
            view.refreshHeight()
        }
        if focused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !focused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// The height the message box needs at the width it is given (the text
    /// view grows with its text; UIKit doesn't tell SwiftUI when).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PasteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// A text view whose Paste takes a picture when the clipboard has one.
    final class PasteTextView: UITextView {
        var onImagePaste: ((UIImage) -> Void)?
        /// Where it stops growing and starts scrolling (lineLimit's upper end).
        var maxLines = 8

        private var lastWidth: CGFloat = 0
        private var lastFit: CGFloat = 0
        private var maxHeight: CGFloat {
            ceil((font?.lineHeight ?? 20) * CGFloat(maxLines))
        }

        /// The height for `width`, capped at `maxLines`.
        func height(forWidth width: CGFloat) -> CGFloat {
            let fit = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            return min(max(fit, font?.lineHeight ?? 20), maxHeight)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.width != lastWidth {
                lastWidth = bounds.width
                refreshHeight()
            }
        }

        /// Re-measure after the text changed: scroll inside once it no
        /// longer fits, so the composer never swallows the transcript.
        func refreshHeight() {
            let width = bounds.width > 0 ? bounds.width : 320
            let fit = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            guard abs(fit - lastFit) > 0.5 else { return }
            lastFit = fit
            isScrollEnabled = fit > maxHeight
            invalidateIntrinsicContentSize()
        }

        /// A copied picture wins: iOS puts no plain text on a copied photo,
        /// and the person asked for the picture by pasting it here.
        override func paste(_ sender: Any?) {
            let board = UIPasteboard.general
            if board.hasImages, let image = board.image {
                onImagePaste?(image)
                return
            }
            super.paste(sender)
        }

        /// Show Paste for an image clipboard even though there is no text
        /// (UIKit's own answer is about text only).
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(UIResponderStandardEditActions.paste(_:)), UIPasteboard.general.hasImages {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            (view as? PasteTextView)?.refreshHeight()
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}
