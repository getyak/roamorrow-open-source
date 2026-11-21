import SwiftUI

struct TripMuseHandoffView: View {
    let workspace: TripWorkspace
    var record: TripRecord?
    let onSaved: (TripRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @State private var response = ""
    @State private var draft: TripProposal?
    @State private var notice: String?
    @State private var copied = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    TripProposalReview(proposal: draft, prior: record?.plan, title: tripText("review", "Review changes")) {
                        save(draft)
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) { Text(tripText("review", "Review changes")).font(.headline) }
                    }
                } else {
                    handoff
                }
            }
            .navigationTitle(tripText("muse.title", "Plan with Muse"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(draft == nil ? tripText("close", "Close") : tripText("back", "Back")) {
                        if draft != nil { draft = nil } else { dismiss() }
                    }
                }
            }
            .alert(tripText("muse.reviewError", "Couldn’t open a preview"), isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } }
            )) {
                Button(tripText("done", "Done")) { notice = nil }
            } message: { Text(notice ?? "") }
            .onChange(of: TravelResearchService.shared.currentScope) { _, _ in dismiss() }
        }
    }

    private var handoff: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text(record == nil ? tripText("muse.new.heading", "Where are you going?") : tripText("muse.edit.heading", "What would you change?"))
                    .font(.system(.title, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(record == nil
                     ? tripText("muse.new.hint", "Copy a request to Muse, then bring back the draft to review it here.")
                     : tripText("muse.edit.hint", "The request includes this trip’s dates, itinerary and handbook so Muse can propose a change."))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
                TextField(record == nil
                          ? tripText("muse.new.placeholder", "Example: 4 days in Bangkok and Chiang Mai in January")
                          : tripText("muse.edit.placeholder", "Example: Keep dinner, swap the afternoon walk for somewhere indoors"),
                          text: $request, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 12))
                    .focused($inputFocused)
                    .accessibilityIdentifier("trip.muse.request")
                ViewThatFits(in: .horizontal) {
                    HStack { copy; openMuse }
                    VStack(alignment: .leading) { copy; openMuse }
                }
                Divider().padding(.vertical, 7)
                HStack {
                    Text(tripText("muse.paste.title", "Muse’s draft")).font(.headline)
                    Spacer()
                    PasteButton(payloadType: String.self) { items in
                        if let item = items.first { response = item }
                    }
                    .tint(CompanionHomeStyle.accent)
                    .accessibilityIdentifier("trip.muse.paste")
                }
                TextEditor(text: $response)
                    .font(.footnote.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 125)
                    .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 12))
                    .accessibilityLabel(tripText("muse.paste.title", "Muse’s draft"))
                    .accessibilityIdentifier("trip.muse.input")
                Button {
                    inspect()
                } label: {
                    Text(tripText("review", "Review changes")).frame(maxWidth: .infinity, minHeight: 39)
                }
                .buttonStyle(.borderedProminent)
                .tint(CompanionHomeStyle.ink)
                .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("trip.muse.preview")
            }
            .padding(21)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(CompanionHomeStyle.ink)
        .background(CompanionHomeStyle.paper.ignoresSafeArea())
    }

    private var copy: some View {
        Button {
            guard let text = try? TripMuseExchange.request(request, revising: record) else { return }
            UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
            copied = true
            inputFocused = false
            Haptics.selection()
        } label: {
            Label(copied ? tripText("muse.copied", "Copied") : tripText("muse.copy", "Copy request"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .onChange(of: request) { _, _ in copied = false }
    }

    private var openMuse: some View {
        Link(destination: URL(string: "https://muse.ai/")!) {
            Label(tripText("muse.open", "Open Muse"), systemImage: "arrow.up.right")
        }
        .font(.subheadline.bold())
        .padding(.horizontal, 5)
    }

    private func inspect() {
        do {
            draft = try TripMuseExchange.proposal(from: response, for: record)
        } catch {
            notice = tripText("muse.badDraft", "Paste the full draft as returned by Muse. For edits, use a request copied from the latest version of this trip. Locked plans must stay in place.")
        }
    }

    private func save(_ draft: TripProposal) {
        guard workspace.scope == TravelResearchService.shared.currentScope else { return }
        do {
            let saved = try workspace.applyTrip(draft)
            onSaved(saved)
            Haptics.notify(.success)
            dismiss()
        } catch {
            notice = tripText("error.retry", "Open the latest plan and try again.")
        }
    }
}

struct TripProposalReview: View {
    let proposal: TripProposal
    let prior: TripPlan?
    let title: String
    let confirm: () -> Void

    private var changes: [TripPlanChange] { TripPlanChange.between(prior, and: proposal.plan) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(proposal.summary).font(.subheadline)
                    .foregroundStyle(CompanionHomeStyle.secondaryInk)
                    .accessibilityIdentifier("trip.review.summary")
                if prior == nil {
                    Text(proposal.plan.title).font(.headline)
                    ForEach(proposal.plan.days) { day in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(tripDateLabel(day)) · \(day.city.name)").font(.subheadline.bold())
                            if day.stops.isEmpty { Text(tripText("review.freeDay", "Free day")).font(.footnote) }
                            ForEach(day.stops.sorted { $0.time < $1.time }) { stop in
                                Text("\(stop.time)  \(stop.title)").font(.footnote)
                            }
                        }
                    }
                    if !proposal.plan.handbook.isEmpty {
                        DisclosureGroup(tripText("handbook", "Handbook")) {
                            ForEach(proposal.plan.handbook) { item in
                                Text(item.title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                } else {
                    ForEach(changes) { change in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: change.symbol).frame(width: 19).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.title).font(.subheadline.bold())
                                if let before = change.before {
                                    Text(before).strikethrough().font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                                }
                                if let after = change.after { Text(after).font(.footnote) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 12))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("trip.change.\(change.id)")
                    }
                    let changedDate = Set(changes.flatMap(\.dates))
                    let preserved = proposal.plan.days.filter { changedDate.contains($0.date) }
                        .flatMap { day in day.stops.filter(\.locked).map { "\(tripDateLabel(day)) · \($0.time)  \($0.title)" } }
                    if !preserved.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(tripText("review.preserved", "Locked plans stay in place"), systemImage: "lock").font(.headline)
                            ForEach(Array(preserved.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline) }
                        }
                        .accessibilityIdentifier("trip.review.locked")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: confirm) {
                Text(prior == nil ? tripText("save", "Save trip") : tripText("confirm", "Apply changes"))
                    .frame(maxWidth: .infinity, minHeight: 39)
            }
            .buttonStyle(.borderedProminent)
            .tint(CompanionHomeStyle.ink)
            .foregroundStyle(CompanionHomeStyle.paper)
            .accessibilityIdentifier("trip.confirm")
            .padding(18)
            .background(CompanionHomeStyle.paper)
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .background(CompanionHomeStyle.paper.ignoresSafeArea())
    }
}
