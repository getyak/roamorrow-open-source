import SwiftUI
import UIKit

/// The UUID identifies the persisted response; the index identifies one visible bubble.
/// Keep the native menu and its preview on this surface, never on the response stack.
@MainActor
struct CompanionMessageActionsView<Content: View>: View {
    let entryID: UUID
    let partIndex: Int
    let text: String
    let previewQuote: String?
    let attachmentNames: [String]
    let isOutgoing: Bool
    let isActive: Bool
    let reactions: [String]
    let hasSources: Bool
    let onQuote: () -> Void
    let onReaction: (String) -> Void
    let onSources: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var showsPicker = false
    private let commitDistance: CGFloat = 58
    private let heart = "❤️"
    private var identity: String { "\(entryID).\(partIndex)" }
    private var quoteLabel: String { companionText("companion.im.reply", "引用回复") }

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: -13) {
            ZStack(alignment: .leading) {
                if isActive && offset > 10 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CompanionHomeStyle.accent)
                        .frame(width: 32, height: 32)
                        .background(CompanionHomeStyle.accent.opacity(0.10), in: Circle())
                        .padding(.leading, 4)
                        .opacity(min(1, (offset - 10) / 32))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                surface.offset(x: offset)
            }
            if !reactions.isEmpty {
                reactionBadge
                    .padding(.horizontal, 10)
                    .offset(x: offset)
            }
        }
        .sheet(isPresented: $showsPicker) {
            CompanionReactionPicker(selected: reactions, onReaction: onReaction)
        }
        .onChange(of: isActive) { _, active in
            if !active { offset = 0; showsPicker = false }
        }
    }

    @ViewBuilder private var reactionBadge: some View {
        if reactions.count == 1, let emoji = reactions.first {
            Button { onReaction(emoji) } label: { reactionPill }
                .buttonStyle(.plain)
                .accessibilityLabel(reactionLabel(emoji, selected: true))
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("companion.reaction.selected.\(identity).\(emoji)")
        } else {
            Menu {
                ForEach(reactions, id: \.self) { emoji in
                    Button(reactionLabel(emoji, selected: true)) { onReaction(emoji) }
                }
            } label: { reactionPill }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(companionText("companion.im.myReactions", "我的回应"))
                .accessibilityValue(reactions.joined(separator: " "))
        }
    }

    private var reactionPill: some View {
        HStack(spacing: 4) {
            ForEach(Array(reactions.prefix(4)), id: \.self) { emoji in
                if emoji == heart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionHomeStyle.reactionHeart)
                } else {
                    Text(emoji).font(.system(size: 12))
                }
            }
            if reactions.count > 4 {
                Text("+\(reactions.count - 4)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(CompanionHomeStyle.secondaryInk)
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 22, minHeight: 21)
        .background(CompanionHomeStyle.paper, in: Capsule())
        .overlay(Capsule().strokeBorder(CompanionHomeStyle.accent.opacity(0.14), lineWidth: 0.75))
        .frame(minWidth: 44, minHeight: 44, alignment: isOutgoing ? .trailing : .leading)
        .contentShape(Rectangle())
    }

    private var surface: some View {
        content()
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(isOutgoing ? CompanionHomeStyle.outgoing : CompanionHomeStyle.incoming,
                        in: RoundedRectangle(cornerRadius: 21, style: .continuous))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlayPreferenceValue(CompanionMessageControlBounds.self) { anchors in
                GeometryReader { proxy in
                    CompanionQuoteSwipeSurface(isActive: isActive, exclusions: anchors.map { proxy[$0] },
                        onChange: moveReply, onEnd: finishSwipe, onDoubleTap: addHeart)
                }
            }
            .contextMenu {
                ControlGroup {
                    ForEach(CompanionReaction.quick, id: \.self) { emoji in
                        Button { onReaction(emoji) } label: {
                            Text(emoji).font(.title2).frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(reactionLabel(emoji, selected: reactions.contains(emoji)))
                        .accessibilityIdentifier("companion.reaction.quick.\(identity).\(emoji)")
                        .menuActionDismissBehavior(.enabled)
                    }
                }.controlGroupStyle(.palette).menuActionDismissBehavior(.enabled)
                Button(companionText("companion.im.moreReactions", "更多表情"), systemImage: "face.smiling") { showsPicker = true }
                Button(quoteLabel, systemImage: "arrowshape.turn.up.left", action: quote)
                if !text.isEmpty {
                    Button(companionText("companion.im.copy", "复制文字"), systemImage: "doc.on.doc") { copy() }
                }
                if hasSources {
                    Button(companionText("companion.sources.open", "查看依据"), systemImage: "text.quote", action: onSources)
                }
            } preview: {
                preview
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text.isEmpty ? attachmentNames.joined(separator: ", ") : text)
            .accessibilityActions {
                Button(quoteLabel, action: quote)
                if !text.isEmpty { Button(companionText("companion.im.copy", "复制文字"), action: copy) }
                Button(companionText("companion.im.moreReactions", "更多表情")) { showsPicker = true }
                ForEach(CompanionReaction.quick, id: \.self) { emoji in
                    Button(reactionLabel(emoji, selected: reactions.contains(emoji))) { onReaction(emoji) }
                }
                if hasSources { Button(companionText("companion.sources.open", "查看依据"), action: onSources) }
            }
            .accessibilityIdentifier("companion.bubble.\(identity)")
    }

    /// A passive copy prevents a context-menu preview from starting playback or Speech tasks.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let previewQuote {
                Text(previewQuote).font(.subheadline).lineLimit(3)
                    .foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { CompanionHomeStyle.accent.opacity(0.5).frame(width: 2) }
            }
            ForEach(Array(attachmentNames.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "paperclip").font(.subheadline)
            }
            if !text.isEmpty { Text(text).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 320, alignment: .leading)
        .foregroundStyle(CompanionHomeStyle.ink)
        .background(isOutgoing ? CompanionHomeStyle.outgoing : CompanionHomeStyle.incoming,
                    in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .accessibilityIdentifier("companion.preview.\(identity)")
    }

    private func copy() { UIPasteboard.general.string = text }
    private func quote() { reset(); onQuote() }
    private func reset() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { offset = 0 }
    }
    private func moveReply(_ translation: CGFloat) {
        if offset < commitDistance && translation >= commitDistance { Haptics.selection() }
        offset = min(commitDistance + 10, max(0, translation))
    }

    private func finishSwipe(_ translation: CGFloat, _ cancelled: Bool) {
        if !cancelled && translation >= commitDistance { quote() }
        else { reset() }
    }

    private func addHeart() {
        guard !reactions.contains(heart) else { return }
        Haptics.selection()
        onReaction(heart)
    }
}

private func reactionLabel(_ emoji: String, selected: Bool) -> String {
    String(format: selected
        ? companionText("companion.im.removeReaction", "移除我添加的 %@ 表情")
        : companionText("companion.im.addReaction", "添加 %@ 表情"), emoji)
}

@MainActor
private struct CompanionReactionPicker: View {
    let selected: [String]
    let onReaction: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 90), spacing: 10)], spacing: 10) {
                    ForEach(CompanionReaction.all, id: \.self) { emoji in
                        Button { onReaction(emoji); dismiss() } label: {
                            Text(emoji).font(.largeTitle).frame(minWidth: 56, minHeight: 56)
                                .frame(maxWidth: .infinity)
                                .background(selected.contains(emoji) ? CompanionHomeStyle.outgoing : CompanionHomeStyle.incoming,
                                            in: RoundedRectangle(cornerRadius: 16))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(reactionLabel(emoji, selected: selected.contains(emoji)))
                            .accessibilityAddTraits(selected.contains(emoji) ? .isSelected : [])
                            .accessibilityIdentifier("companion.reaction.picker.\(emoji)")
                    }
                }.padding(20)
            }
            .background(CompanionHomeStyle.paper)
            .navigationTitle(companionText("companion.im.moreReactions", "更多表情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(companionText("companion.done", "完成")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Explicit exclusions keep taps and drags that start on media/buttons in their
/// original controls. The pan recognizer belongs to this bubble's overlay UIView.
struct CompanionMessageControlBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

extension View {
    func companionMessageControl() -> some View {
        anchorPreference(key: CompanionMessageControlBounds.self, value: .bounds) { [$0] }
    }
}

private struct CompanionQuoteSwipeSurface: UIViewRepresentable {
    let isActive: Bool
    let exclusions: [CGRect]
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, Bool) -> Void
    let onDoubleTap: () -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.active = isActive
        view.exclusions = exclusions
        view.onChange = onChange
        view.onEnd = onEnd
        view.onDoubleTap = onDoubleTap
        view.pan.isEnabled = isActive
    }

    @MainActor final class Surface: UIView, UIGestureRecognizerDelegate {
        var active = true
        var exclusions: [CGRect] = []
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat, Bool) -> Void)?
        var onDoubleTap: (() -> Void)?
        private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }
        required init?(coder: NSCoder) { nil }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            active && bounds.contains(point) && !exclusions.contains { $0.contains(point) }
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pan else { return true }
            let velocity = pan.velocity(in: self)
            return active && velocity.x > abs(velocity.y) * 1.5
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // No changes to the shared scroll view's delegate or failure dependencies.
            otherGestureRecognizer.view is UIScrollView
        }
        @objc private func tapped() { onDoubleTap?() }
        @objc private func dragged() {
            // Use a fixed ancestor coordinate space: moving this view must not feed
            // its own visual offset back into the recognizer's translation.
            let x = pan.translation(in: window).x
            switch pan.state {
            case .began, .changed: onChange?(x)
            case .ended: onEnd?(x, false)
            case .cancelled, .failed: onEnd?(x, true)
            default: break
            }
        }
    }
}
