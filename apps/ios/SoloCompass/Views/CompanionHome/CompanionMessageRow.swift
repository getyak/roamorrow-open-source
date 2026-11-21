import SwiftUI

@MainActor
struct CompanionMessageRow: View {
    let entry: CompanionHomeEntry
    var replyContext: String? = nil
    var isActive = true
    let onRetry: () -> Void
    let onSources: () -> Void
    let onPlace: (String) -> Void
    let onMedia: (CompanionMediaAttachment) -> Void
    let onQuote: (CompanionQuotedMessage) -> Void
    let onReaction: (Int, String) -> Void
    let onTranscript: (UUID, String?) -> Bool
    @Environment(ExperienceService.self) private var experiences
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isUser: Bool { entry.role == .user }
    private var parts: [String] {
        let response = isUser ? entry.text : CompanionHomeAgent.userFacingResponse(entry.text)
        guard !isUser, (entry.attachments ?? []).isEmpty, entry.quotedMessage == nil,
              replyContext == nil, entry.placeID == nil else { return response.isEmpty ? [] : [response] }
        return CompanionReplyLayout.parts(response)
    }
    private var hasSources: Bool { !entry.sourceTitles.isEmpty || !entry.mapPlaceIDs.isEmpty }

    var body: some View {
        let parts = self.parts.isEmpty ? [""] : self.parts
        return HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: typeSize.isAccessibilitySize ? 8 : 30) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    let isLast = index == parts.count - 1
                    let selectedText = actionText(part, isLast: isLast)
                    CompanionMessageActionsView(entryID: entry.id, partIndex: index, text: selectedText,
                        previewQuote: isLast ? (entry.quotedMessage?.text ?? replyContext) : nil,
                        attachmentNames: isLast ? (entry.attachments ?? []).map(\.name) : [],
                        isOutgoing: isUser, isActive: isActive,
                        reactions: entry.reactions(forPart: index), hasSources: hasSources,
                        onQuote: { onQuote(quotation(partIndex: index, text: selectedText)) },
                        onReaction: { onReaction(index, $0) }, onSources: onSources) {
                        bubbleContent(part: part, index: index, isLast: isLast)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion.message.\(entry.id)")
            if !isUser { Spacer(minLength: typeSize.isAccessibilitySize ? 8 : 30) }
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func bubbleContent(part: String, index: Int, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLast {
                if let quote = entry.quotedMessage { quoteBlock(quote.text) }
                else if let replyContext { quoteBlock(replyContext) }
                ForEach(entry.attachments ?? []) { attachment in
                    if attachment.kind == .audio {
                        CompanionAudioMessage(attachment: attachment, isActive: isActive,
                            isPreparingReply: isUser && (entry.status == .queued || entry.status == .working),
                            onTranscript: { onTranscript(attachment.id, $0) },
                            onOpen: { onMedia(attachment) })
                    } else {
                        CompanionMediaTile(attachment: attachment) { onMedia(attachment) }
                            .companionMessageControl()
                        if let text = attachment.extractedText, !text.isEmpty {
                            DisclosureGroup {
                                Text(text).font(.subheadline).padding(.top, 8)
                                    .fixedSize(horizontal: false, vertical: true)
                            } label: {
                                Text(companionText("companion.media.extracted", "查看识别文字 · 请核对"))
                                    .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .font(.footnote).tint(CompanionHomeStyle.ink)
                            .companionMessageControl()
                        }
                    }
                }
            }
            if !part.isEmpty {
                // Long press has one owner: the bubble's native action menu.
                formatted(part).font(.body).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(index == 0 ? bodyIdentifier : "companion.message.part.\(entry.id).\(index)")
            }
            if isLast { trailingContent }
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        if !isUser, let reference = entry.researchReference {
            TravelResearchCard(reference: reference).companionMessageControl()
        }
        ForEach(entry.mapPlaceIDs.prefix(3), id: \.self) { id in
            if let experience = experiences.getExperience(id: id) {
                Button { onPlace(id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(experience.shortName).font(.body.weight(.medium))
                            Text(companionText("companion.map.showResult", "在地图上看"))
                                .font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote).accessibilityHidden(true)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("companion.message.map.\(entry.id).\(id)")
                .companionMessageControl()
            }
        }
        if !entry.mapPlaceIDs.isEmpty || entry.sourceTitles.contains(where: { $0.hasPrefix("本轮网页检索") || $0.hasPrefix("工具返回资料") }) {
            Button(action: onSources) {
                Label(companionText("companion.sources.open", "查看依据"), systemImage: "text.quote")
                    .font(.footnote).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(CompanionHomeStyle.secondaryInk)
            .accessibilityIdentifier("companion.sources.\(entry.id)")
            .companionMessageControl()
        }
        if isUser && (entry.status == .failed || entry.status == .queued) {
            Button(action: onRetry) {
                Label(companionText("companion.im.retry", "尚未完成 · 重试"), systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("companion.retry.\(entry.id)")
            .companionMessageControl()
        }
    }

    private func actionText(_ part: String, isLast: Bool) -> String {
        guard isLast else { return part }
        let spoken = (entry.attachments ?? []).filter { $0.kind == .audio }.compactMap(\.extractedText)
            .filter { !$0.isEmpty && $0 != part }
        return ([part] + spoken).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private func quotation(partIndex: Int, text: String) -> CompanionQuotedMessage {
        .init(entryID: entry.id, role: entry.role,
              text: String((text.isEmpty ? (entry.attachments?.first?.name ?? "") : text).prefix(600)), partIndex: partIndex)
    }
    private func quoteBlock(_ text: String) -> some View {
        Text(text).font(.subheadline).lineLimit(3).foregroundStyle(CompanionHomeStyle.secondaryInk)
            .padding(.leading, 10).padding(.vertical, 4)
            .overlay(alignment: .leading) { CompanionHomeStyle.accent.opacity(0.5).frame(width: 2) }
            .accessibilityLabel(companionText("companion.im.quoted", "引用") + "：" + text)
    }
    private var bodyIdentifier: String {
        entry.replyToID.map { "companion.reply-to.\($0)" } ?? "companion.message.body.\(entry.id)"
    }
    private func formatted(_ response: String) -> some View {
        CompanionFormattedMessageText(response: response, isUser: isUser).equatable()
    }
}

/// Value-only inputs let SwiftUI retain parsed text while scroll state changes.
private struct CompanionFormattedMessageText: View, Equatable {
    let response: String
    let isUser: Bool
    var body: some View { rendered }

    private var rendered: Text {
        guard !isUser else { return Text(response) }
        guard var formatted = try? AttributedString(markdown: response,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return Text(response) }
        let ranges = formatted.runs.compactMap { $0.link == nil ? nil : $0.range }
        for range in ranges { formatted[range].link = nil }
        return Text(formatted)
    }
}
