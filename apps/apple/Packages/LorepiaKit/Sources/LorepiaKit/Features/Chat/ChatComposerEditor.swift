#if os(iOS)
import SwiftUI
import UIKit

/// A persistent native editor that resolves wrapping atomically.
///
/// A multiline SwiftUI `TextField` reports its new intrinsic height after
/// TextKit has already committed the wrapped glyphs. When the resolved height
/// changes, this host briefly carries a native rendering of the remaining
/// lines with the surrounding SwiftUI layout. The complete new layout and
/// caret replace that rendering after the surface settles, so no glyph travels
/// through a clipping boundary or appears twice in either direction.
struct ChatComposerEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    let focus: FocusState<Bool>.Binding
    let placeholder: String
    let isEnabled: Bool
    let minimumLines: Int
    let maximumLines: Int
    let automaticFocusID: String?
    let animatesHeightChanges: Bool
    let onSubmit: () -> Void
    let onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ChatComposerEditorHost {
        let host = ChatComposerEditorHost()
        let textView = host.textView

        textView.delegate = context.coordinator
        textView.text = text
        textView.selectedRange = NSRange(
            location: text.utf16.count,
            length: 0
        )
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.textContainerInset = UIEdgeInsets(
            top: ChatComposerEditorHost.textVerticalInset,
            left: 0,
            bottom: ChatComposerEditorHost.textVerticalInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.keyboardDismissMode = .interactive
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = false
        textView.returnKeyType = .send
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.accessibilityIdentifier = "chat-composer-field"
        textView.accessibilityLabel = placeholder
        textView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        host.updatePlaceholder(placeholder)
        host.updatePlaceholderVisibility()
        host.onWidthChange = { [weak coordinator = context.coordinator] host in
            coordinator?.hostWidthDidChange(host)
        }
        context.coordinator.host = host
        context.coordinator.synchronizeHeight(
            in: host,
            updatesTextBinding: false
        )
        return host
    }

    func updateUIView(
        _ host: ChatComposerEditorHost,
        context: Context
    ) {
        context.coordinator.parent = self

        let textView = host.textView
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.accessibilityLabel = placeholder
        host.updatePlaceholder(placeholder)

        // Never overwrite a marked range while Korean, Chinese, or Japanese
        // input is still composing. The delegate remains the source of truth
        // until TextKit commits that range.
        if textView.markedTextRange == nil, textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = NSRange(
                location: min(selection.location, text.utf16.count),
                length: 0
            )
            host.updatePlaceholderVisibility()
            context.coordinator.synchronizeHeight(
                in: host,
                updatesTextBinding: false
            )
        } else {
            // Keep the native constraint, SwiftUI state, and sizeThatFits
            // result in sync when Dynamic Type or the line cap changes without
            // changing the draft text.
            context.coordinator.synchronizeHeight(
                in: host,
                updatesTextBinding: false
            )
        }

        context.coordinator.synchronizeFocus(in: textView)
        context.coordinator.requestAutomaticFocus(in: textView)
    }

    static func dismantleUIView(
        _ host: ChatComposerEditorHost,
        coordinator: Coordinator
    ) {
        coordinator.cancelAutomaticFocus()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView host: ChatComposerEditorHost,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else {
            return nil
        }
        let measurement = host.measure(
            width: width,
            minimumLines: minimumLines,
            maximumLines: maximumLines
        )
        return CGSize(width: width, height: measurement.height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatComposerEditor
        weak var host: ChatComposerEditorHost?

        private var lastReportedHeight: CGFloat = 0
        private var lastRequestedFocus = false
        private var lastAutomaticFocusID: String?
        private var automaticFocusTask: Task<Void, Never>?

        init(parent: ChatComposerEditor) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focus.wrappedValue {
                parent.focus.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            cancelAutomaticFocus()
            if parent.focus.wrappedValue {
                parent.focus.wrappedValue = false
            }
            parent.onEndEditing()
        }

        func synchronizeFocus(in textView: UITextView) {
            let requestedFocus = parent.focus.wrappedValue
            if requestedFocus {
                if !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                }
            } else if lastRequestedFocus {
                cancelAutomaticFocus()
                // A native tap reaches the delegate before SwiftUI publishes
                // its FocusState mutation. Only a real true-to-false request
                // should resign; treating that transient initial false as an
                // instruction makes the keyboard immediately flicker away.
                if textView.isFirstResponder {
                    textView.resignFirstResponder()
                }
            }
            lastRequestedFocus = requestedFocus
        }

        func requestAutomaticFocus(in textView: UITextView) {
            guard let focusID = parent.automaticFocusID else {
                cancelAutomaticFocus()
                lastAutomaticFocusID = nil
                return
            }
            guard focusID != lastAutomaticFocusID else {
                return
            }

            lastAutomaticFocusID = focusID
            automaticFocusTask?.cancel()
            automaticFocusTask = Task { @MainActor [weak self, weak textView] in
                for attempt in 0 ..< 8 {
                    if attempt > 0 {
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            return
                        }
                    } else {
                        await Task.yield()
                    }

                    guard !Task.isCancelled,
                          let self,
                          let textView,
                          self.parent.automaticFocusID == focusID,
                          self.parent.isEnabled
                    else {
                        return
                    }
                    guard textView.window != nil else {
                        continue
                    }

                    self.parent.focus.wrappedValue = true
                    if textView.becomeFirstResponder() {
                        self.automaticFocusTask = nil
                        return
                    }
                }
                guard let self,
                      self.parent.automaticFocusID == focusID
                else {
                    return
                }
                self.automaticFocusTask = nil
            }
        }

        func cancelAutomaticFocus() {
            automaticFocusTask?.cancel()
            automaticFocusTask = nil
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let host else {
                return
            }
            host.updatePlaceholderVisibility()
            synchronizeHeight(
                in: host,
                updatesTextBinding: true
            )
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn _: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n", textView.markedTextRange == nil {
                parent.onSubmit()
                return false
            }
            return true
        }

        func hostWidthDidChange(_ host: ChatComposerEditorHost) {
            host.cancelHeightTransition()
            synchronizeHeight(
                in: host,
                updatesTextBinding: false
            )
        }

        func synchronizeHeight(
            in host: ChatComposerEditorHost,
            updatesTextBinding: Bool
        ) {
            let width = host.bounds.width
            guard width > 0 else {
                return
            }

            let measurement = host.measure(
                width: width,
                minimumLines: parent.minimumLines,
                maximumLines: parent.maximumLines
            )
            host.updateScrolling(
                shouldScroll: measurement.exceedsMaximum
            )

            let previousHeight = max(
                lastReportedHeight,
                parent.measuredHeight
            )
            let heightChanged =
                abs(measurement.height - previousHeight) > 0.5
            var animatesResizeWhileTyping =
                updatesTextBinding
                    && parent.animatesHeightChanges
                    && lastReportedHeight > 0
                    && heightChanged
                    && !measurement.exceedsMaximum
            var heightTransitionToken: UUID?

            if heightChanged {
                host.setHeight(measurement.height)
                if animatesResizeWhileTyping {
                    heightTransitionToken =
                        host.beginHeightTransition(
                            visibleHeight: min(
                                previousHeight,
                                measurement.height
                            ),
                            resolvedHeight: measurement.height
                        )
                    animatesResizeWhileTyping =
                        heightTransitionToken != nil
                } else {
                    host.cancelHeightTransition()
                }
                lastReportedHeight = measurement.height
            } else if lastReportedHeight == 0 {
                lastReportedHeight = measurement.height
                host.setHeight(measurement.height)
            }

            let newText = host.textView.text ?? ""
            if
                !heightChanged,
                host.isHeightTransitionActive,
                updatesTextBinding
            {
                if measurement.exceedsMaximum {
                    // Once the editor reaches its line cap, there is no
                    // remaining geometry transition to animate. Hand the
                    // surface back to the live text view immediately so the
                    // caret and accessibility element cannot be stranded
                    // behind a superseded transition snapshot.
                    host.cancelHeightTransition()
                } else {
                    host.refreshHeightTransition()
                }
            }

            let updateBindings = {
                if updatesTextBinding, self.parent.text != newText {
                    self.parent.text = newText
                }
                if abs(
                    self.parent.measuredHeight - measurement.height
                ) > 0.5 {
                    self.parent.measuredHeight = measurement.height
                }
            }
            if
                animatesResizeWhileTyping,
                let heightTransitionToken
            {
                withAnimation(
                    .smooth(
                        duration:
                            ChatComposerEditorHost.heightAnimationDuration
                    ),
                    completionCriteria: .removed
                ) {
                    updateBindings()
                } completion: { [weak host] in
                    host?.finishHeightTransition(
                        token: heightTransitionToken
                    )
                }
            } else {
                updateBindings()
            }
        }
    }
}

@MainActor
final class ChatComposerEditorHost: UIView {
    static let textVerticalInset: CGFloat = 1
    static let heightAnimationDuration: TimeInterval = 0.24

    struct Measurement {
        let height: CGFloat
        let exceedsMaximum: Bool
    }

    let textView = UITextView(frame: .zero)
    var onWidthChange: ((ChatComposerEditorHost) -> Void)?

    private let placeholderLabel = UILabel()
    private var textViewHeightConstraint: NSLayoutConstraint!
    private var previousWidth: CGFloat = 0
    private var transitionSnapshotView: UIImageView?
    private var transitionVisibleHeight: CGFloat = 0
    private var transitionToken: UUID?

    var isHeightTransitionActive: Bool {
        transitionSnapshotView != nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureHierarchy()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTransitionSnapshotFrame()
        guard abs(bounds.width - previousWidth) > 0.5 else {
            return
        }
        previousWidth = bounds.width
        onWidthChange?(self)
    }

    func updatePlaceholder(_ placeholder: String) {
        placeholderLabel.text = placeholder
        placeholderLabel.font =
            textView.font ?? UIFont.preferredFont(forTextStyle: .body)
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    func measure(
        width: CGFloat,
        minimumLines: Int,
        maximumLines: Int
    ) -> Measurement {
        let font =
            textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let lineHeight = font.lineHeight
        let insets = textView.textContainerInset.top
            + textView.textContainerInset.bottom
        let boundedMinimumLines = min(
            max(minimumLines, 1),
            max(maximumLines, 1)
        )
        let minimumHeight = pixelCeil(
            lineHeight * CGFloat(boundedMinimumLines) + insets
        )
        let maximumHeight = pixelCeil(
            lineHeight * CGFloat(max(maximumLines, 1)) + insets
        )
        let fittingHeight = pixelCeil(
            textView.sizeThatFits(
                CGSize(
                    width: width,
                    height: .greatestFiniteMagnitude
                )
            ).height
        )
        return Measurement(
            height: min(
                max(fittingHeight, minimumHeight),
                maximumHeight
            ),
            exceedsMaximum: fittingHeight > maximumHeight + 0.5
        )
    }

    func updateScrolling(shouldScroll: Bool) {
        if shouldScroll {
            textView.scrollRangeToVisible(textView.selectedRange)
        } else {
            textView.setContentOffset(.zero, animated: false)
        }
    }

    func setHeight(_ height: CGFloat) {
        guard
            abs(height - textViewHeightConstraint.constant) > 0.5
        else {
            return
        }

        UIView.performWithoutAnimation {
            textViewHeightConstraint.constant = height
            layoutIfNeeded()
        }
    }

    /// Keeps the already-resolved native lines visually attached to the glass
    /// rim while SwiftUI changes the editor's line count.
    ///
    /// The old visible lines use a snapshot of this exact text view while a
    /// single newly-created line is exposed through a disjoint lower mask.
    /// That new line fades in whole at its final baseline, so no glyph crosses
    /// a clipping boundary and the top line is never rendered twice.
    @discardableResult
    func beginHeightTransition(
        visibleHeight: CGFloat,
        resolvedHeight: CGFloat
    ) -> UUID? {
        cancelHeightTransition()
        guard
            visibleHeight > 0,
            resolvedHeight > 0,
            bounds.width > 0,
            let image = renderedTextSnapshot(
                visibleHeight: visibleHeight
            )
        else {
            return nil
        }

        let snapshotView = UIImageView(image: image)
        snapshotView.backgroundColor = .clear
        snapshotView.isUserInteractionEnabled = false
        snapshotView.isAccessibilityElement = false
        snapshotView.contentMode = .scaleToFill
        transitionVisibleHeight = visibleHeight
        transitionSnapshotView = snapshotView
        addSubview(snapshotView)
        bringSubviewToFront(snapshotView)
        updateTransitionSnapshotFrame()

        let additionalLineMask = makeAdditionalLineRevealMask(
            visibleHeight: visibleHeight,
            resolvedHeight: resolvedHeight
        )
        let token = UUID()
        transitionToken = token

        UIView.performWithoutAnimation {
            textView.layer.removeAnimation(forKey: "opacity")
            textView.layer.mask = additionalLineMask
            // A lower mask lets the final line render without exposing the
            // live top line behind its snapshot. Other resize directions keep
            // the live pixels hidden until the geometry is complete.
            textView.layer.opacity =
                additionalLineMask == nil ? 0 : 1
            snapshotView.alpha = 1
        }
        if let additionalLineMask {
            animateAdditionalLineReveal(additionalLineMask)
        }
        return token
    }

    func refreshHeightTransition() {
        guard
            let snapshotView = transitionSnapshotView,
            let image = renderedTextSnapshot(
                visibleHeight: transitionVisibleHeight
            )
        else {
            return
        }
        snapshotView.image = image
    }

    func cancelHeightTransition() {
        transitionToken = nil
        transitionSnapshotView?.removeFromSuperview()
        transitionSnapshotView = nil
        transitionVisibleHeight = 0
        textView.layer.mask?.removeAllAnimations()
        textView.layer.mask = nil
        textView.layer.removeAnimation(forKey: "opacity")
        UIView.performWithoutAnimation {
            textView.layer.opacity = 1
        }
    }

    private func configureHierarchy() {
        clipsToBounds = true
        isAccessibilityElement = false

        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        textViewHeightConstraint = textView.heightAnchor.constraint(
            equalToConstant: 22
        )
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textViewHeightConstraint
        ])

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(
                equalTo: textView.frameLayoutGuide.leadingAnchor
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo:
                    textView.frameLayoutGuide.trailingAnchor
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.frameLayoutGuide.topAnchor,
                constant: Self.textVerticalInset
            )
        ])
    }

    func finishHeightTransition(token: UUID) {
        guard transitionToken == token else {
            return
        }
        transitionToken = nil
        guard let snapshotView = transitionSnapshotView else {
            UIView.performWithoutAnimation {
                textView.layer.mask?.removeAllAnimations()
                textView.layer.mask = nil
                textView.layer.opacity = 1
            }
            return
        }

        // At this point both renderings occupy the exact final geometry.
        // Swap them within one disabled-animation transaction instead of
        // cross-fading two antialiased glyph rasters, which creates a visible
        // grey duplicate and a late brightness pulse.
        UIView.performWithoutAnimation {
            textView.layer.mask?.removeAllAnimations()
            textView.layer.removeAnimation(forKey: "opacity")
            snapshotView.removeFromSuperview()
            textView.layer.mask = nil
            textView.layer.opacity = 1
        }
        guard transitionSnapshotView === snapshotView else {
            return
        }
        transitionSnapshotView = nil
        transitionVisibleHeight = 0
    }

    private func updateTransitionSnapshotFrame() {
        transitionSnapshotView?.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: transitionVisibleHeight
        )
    }

    private func renderedTextSnapshot(
        visibleHeight: CGFloat
    ) -> UIImage? {
        guard
            bounds.width > 0,
            visibleHeight > 0,
            textView.bounds.width > 0,
            textView.bounds.height > 0
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(traitCollection.displayScale, 1)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(
                width: bounds.width,
                height: visibleHeight
            ),
            format: format
        )
        let savedMask = textView.layer.mask
        let savedOpacity = textView.layer.opacity
        let savedTintColor = textView.tintColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textView.layer.mask = nil
        textView.layer.opacity = 1
        // The final caret already belongs to the lower live band. Capturing it
        // in the old-height top band exposes only its clipped tip before the
        // surface has opened, which reads as a blue flash at the wrap point.
        textView.tintColor = .clear
        textView.layoutIfNeeded()
        let image = renderer.image { context in
            // Capture the real TextKit layer rather than reconstructing a
            // second UITextView. The top-band raster then matches the live
            // handoff pixel-for-pixel.
            textView.layer.render(in: context.cgContext)
        }
        textView.tintColor = savedTintColor
        textView.layer.mask = savedMask
        textView.layer.opacity = savedOpacity
        CATransaction.commit()
        return image
    }

    private func makeAdditionalLineRevealMask(
        visibleHeight: CGFloat,
        resolvedHeight: CGFloat
    ) -> CALayer? {
        let font =
            textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let addedHeight = resolvedHeight - visibleHeight
        guard
            addedHeight > 0.5,
            addedHeight <= font.lineHeight + 2,
            let selection = textView.selectedTextRange
        else {
            return nil
        }

        layoutIfNeeded()
        let scale = max(traitCollection.displayScale, 1)
        let pixel = 1 / scale
        let expectedLineTop =
            visibleHeight - textView.textContainerInset.bottom
        let caret = textView.caretRect(for: selection.end)
        let lineTopTolerance = max(2 * pixel, font.lineHeight * 0.15)
        guard
            caret.minY >= expectedLineTop - lineTopTolerance,
            expectedLineTop < textView.bounds.height
        else {
            return nil
        }

        let revealTop = max(
            0,
            min(caret.minY, expectedLineTop) - pixel
        )
        let mask = CALayer()
        mask.contentsScale = scale
        mask.backgroundColor = UIColor.white.cgColor
        mask.frame = CGRect(
            x: 0,
            y: revealTop,
            width: textView.bounds.width,
            height: textView.bounds.height - revealTop + pixel
        )
        return mask
    }

    private func animateAdditionalLineReveal(_ mask: CALayer) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.beginTime =
            CACurrentMediaTime() + Self.heightAnimationDuration * 0.5
        animation.duration = Self.heightAnimationDuration / 3
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mask.opacity = 1
        mask.add(animation, forKey: "lorepia.additional-line-reveal")
    }

    private func pixelCeil(_ value: CGFloat) -> CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return ceil(value * scale) / scale
    }
}
#endif
