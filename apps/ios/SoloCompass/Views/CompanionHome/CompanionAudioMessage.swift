import SwiftUI

/// Original audio and its real on-device transcript share one quiet message.
@MainActor
struct CompanionAudioMessage: View {
    let attachment: CompanionMediaAttachment
    let isActive: Bool
    var isPreparingReply = false
    var recognize: (@MainActor (CompanionMediaAttachment) async throws -> String)? = nil
    let onTranscript: (String?) -> Bool
    let onOpen: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var transcriber = CompanionAudioTranscriber()
    @State private var working = false
    @State private var failed = false
    @State private var retry = 0
    @State private var attemptedRetry = -1
    private var enabled: Bool { isActive && scenePhase != .background && !isPreparingReply }
    private var transcript: String? {
        attachment.extractedText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                CompanionMediaTile(attachment: attachment, compact: true, onOpen: onOpen)
                Button(action: onOpen) {
                    Image(systemName: "ellipsis").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(companionText("companion.media.audioDetails", "查看原件与文字"))
                    .accessibilityIdentifier("companion.audio.original.\(attachment.id)")
            }.companionMessageControl()
            if let transcript {
                Text(transcript).font(.body).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("companion.audio.transcript.\(attachment.id)")
            } else if working || isPreparingReply {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(companionText("companion.audio.converting", "正在转文字…"))
                }.font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .accessibilityIdentifier("companion.audio.transcribing.\(attachment.id)")
            } else {
                Button { retry += 1 } label: {
                    Label(companionText("companion.audio.retryTranscript", "重试转文字"), systemImage: "arrow.clockwise")
                        .font(.footnote).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!isActive)
                    .companionMessageControl()
                    .accessibilityIdentifier("companion.audio.retryTranscript.\(attachment.id)")
                if failed || attachment.transcriptionFailed == true {
                    Text(companionText("companion.audio.originalKept", "暂时无法转文字，录音已保留。"))
                        .font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                }
            }
        }
        .task(id: Request(active: enabled, retry: retry)) {
            guard enabled, transcript == nil, retry > attemptedRetry,
                  retry > 0 || (!failed && attachment.transcriptionFailed != true) else { return }
            attemptedRetry = retry
            working = true
            defer { working = false }
            do {
                let text: String
                if let recognize { text = try await recognize(attachment) }
                else { text = try await transcriber.transcribe(attachment) }
                try Task.checkCancellation()
                guard enabled else { return }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw NoSpeech.empty }
                failed = !onTranscript(text)
            } catch {
                failed = true
                // Persist the stopped attempt so returning to the screen does
                // not restart recognition without an explicit retry.
                _ = onTranscript(nil)
            }
        }
        .onDisappear { transcriber.cancel() }
    }

    private struct Request: Equatable { let active: Bool; let retry: Int }
    private enum NoSpeech: Error { case empty }
}
