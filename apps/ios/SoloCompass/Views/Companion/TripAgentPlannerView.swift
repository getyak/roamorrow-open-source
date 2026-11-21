import SwiftUI

struct TripAgentPlannerView: View {
    let workspace: TripWorkspace
    let sourceCity: String?
    let onSaved: (TripRecord) -> Void

    @Environment(AIService.self) private var aiService
    @Environment(ExperienceService.self) private var catalog
    @Environment(UserPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var destinations: [TripPlannerDestination] = []
    @State private var destinationID = ""
    @State private var scenario: TripAgentScenario
    @State private var start = Date()
    @State private var dayCount: Int
    @State private var addsSecondCity = false
    @State private var secondDestinationID = ""
    @State private var secondDayCount = 1
    @State private var interest: ExperienceCategory?
    @State private var draft: TripProposal?
    @State private var error: String?
    @State private var generation: Task<Void, Never>?
    @State private var didSave = false

    init(workspace: TripWorkspace, sourceCity: String?, scenario: TripAgentScenario, onSaved: @escaping (TripRecord) -> Void) {
        self.workspace = workspace
        self.sourceCity = sourceCity
        self.onSaved = onSaved
        _scenario = State(initialValue: scenario)
        _dayCount = State(initialValue: scenario.defaultDayCount)
    }

    private var destination: TripPlannerDestination? { destinations.first { $0.id == destinationID } }
    private var secondDestination: TripPlannerDestination? { destinations.first { $0.id == secondDestinationID } }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = destination?.timeZone ?? .current
        return calendar
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    TripProposalReview(proposal: draft, prior: nil, title: tripText("agent.preview", "Review your draft")) {
                        save(draft)
                    }
                } else {
                    form
                }
            }
            .navigationTitle(tripText("agent.name", "Roamorrow Agent"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(draft == nil ? tripText("close", "Close") : tripText("back", "Back")) {
                        if draft != nil {
                            draft = nil
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .task {
                let mapCity = sourceCity ?? preferences.lastSelectedCity
                destinations = TripAgentPlanner.destinations(in: catalog, selectedCity: mapCity)
                let nearby = TripAgentPlanner.nearbyDestination(
                    in: destinations, origin: TripAgentPlanner.coarseOrigin(from: .shared)
                )
                let selected = mapCity.map(TripAgentPlanner.cityKey).flatMap { key in destinations.first { $0.id == key }?.id }
                destinationID = (scenario == .nearby ? nearby : nil) ?? selected ?? nearby ?? ""
                resetDate()
            }
            .onChange(of: destinationID) { _, new in
                if new == secondDestinationID { secondDestinationID = "" }
                resetDate()
                error = nil
            }
            .onChange(of: scenario) { _, new in
                dayCount = new.defaultDayCount
                resetDate()
                error = nil
            }
            .onChange(of: start) { _, _ in error = nil }
            .onChange(of: dayCount) { _, _ in error = nil }
            .onChange(of: addsSecondCity) { _, _ in error = nil }
            .onChange(of: secondDestinationID) { _, _ in error = nil }
            .onChange(of: secondDayCount) { _, _ in error = nil }
            .onChange(of: interest) { _, _ in error = nil }
            .onChange(of: TravelResearchService.shared.currentScope) { _, _ in dismiss() }
            .onDisappear { generation?.cancel() }
            .alert(tripText("error.save", "Couldn’t save"), isPresented: Binding(
                get: { draft != nil && error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button(tripText("done", "Done")) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(scenario.title, systemImage: scenario.symbol)
                        .font(.system(.title, design: .serif, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(tripText("agent.intro", "Choose a city and dates. Roamorrow will draft a schedule from experiences in its catalog."))
                        .font(.subheadline)
                        .foregroundStyle(CompanionHomeStyle.secondaryInk)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Picker(tripText("agent.scenario", "Trip style"), selection: $scenario) {
                        ForEach(TripAgentScenario.allCases) { value in Text(value.title).tag(value) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("trip.agent.scenario")

                    Divider()
                    Picker(tripText("agent.city", "City"), selection: $destinationID) {
                        Text(tripText("agent.chooseCity", "Choose a city")).tag("")
                        ForEach(destinations) { city in Text(city.name).tag(city.id) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("trip.agent.city")
                    Divider()
                    DatePicker(tripText("agent.start", "Start date"), selection: $start,
                               in: calendar.startOfDay(for: Date())..., displayedComponents: .date)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("trip.agent.start")
                    Divider()
                    Picker(addsSecondCity ? tripText("agent.firstLength", "Days in first city") : tripText("agent.length", "Number of days"),
                           selection: $dayCount) {
                        ForEach(1...7, id: \.self) { value in Text(value, format: .number).tag(value) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("trip.agent.length")
                    Divider()
                    Picker(tripText("agent.interest", "Focus"), selection: $interest) {
                        Text(tripText("agent.anyInterest", "Any")).tag(nil as ExperienceCategory?)
                        ForEach(ExperienceCategory.allCases) { category in
                            Text(category.localizedTitle).tag(Optional(category))
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("trip.agent.interest")

                    Divider()
                    Toggle(tripText("agent.addSecondCity", "Add a second city"), isOn: $addsSecondCity)
                        .frame(minHeight: 44)
                        .disabled(destinations.count < 2 || destination == nil)
                        .accessibilityIdentifier("trip.agent.addSecondCity")
                    if addsSecondCity {
                        Divider()
                        Picker(tripText("agent.secondCity", "Second city"), selection: $secondDestinationID) {
                            Text(tripText("agent.chooseCity", "Choose a city")).tag("")
                            ForEach(destinations.filter { $0.id != destinationID }) { city in
                                Text(city.name).tag(city.id)
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("trip.agent.secondCity")
                        Divider()
                        Picker(tripText("agent.secondLength", "Days in second city"), selection: $secondDayCount) {
                            ForEach(1...7, id: \.self) { value in Text(value, format: .number).tag(value) }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("trip.agent.secondLength")
                    }
                }
                .pickerStyle(.menu)
                .environment(\.timeZone, calendar.timeZone)
                .environment(\.calendar, calendar)
                .padding(.horizontal, 14)
                .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 15))
                .disabled(generation != nil)

                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(CompanionHomeStyle.secondaryInk)
                        .accessibilityIdentifier("trip.agent.error")
                }
                Button(action: generate) {
                    Group {
                        if generation != nil {
                            HStack(spacing: 8) {
                                ProgressView().tint(CompanionHomeStyle.paper)
                                Text(tripText("agent.drafting", "Drafting your trip…"))
                            }
                        } else {
                            Label(tripText("agent.generate", "Draft my trip"), systemImage: "sparkles")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(CompanionHomeStyle.ink)
                .foregroundStyle(CompanionHomeStyle.paper)
                .disabled(destination == nil || (addsSecondCity && secondDestination == nil) || generation != nil)
                .accessibilityIdentifier("trip.agent.generate")
            }
            .frame(maxWidth: 580, alignment: .leading)
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .tint(CompanionHomeStyle.accent)
        .background(CompanionHomeStyle.paper.ignoresSafeArea())
    }

    private func resetDate() {
        start = scenario.defaultDate(in: calendar)
    }

    private func generate() {
        guard generation == nil, let destination, workspace.scope == TravelResearchService.shared.currentScope,
              !addsSecondCity || secondDestination != nil else { return }
        error = nil
        let secondStay = addsSecondCity ? secondDestination.map {
            TripAgentPlanner.Stay(destination: $0, dayCount: secondDayCount)
        } : nil
        let request = TripAgentPlanner.Request(
            destination: destination, scenario: scenario, start: start, dayCount: dayCount, interest: interest,
            coarseOrigin: TripAgentPlanner.coarseOrigin(from: .shared), secondStay: secondStay
        )
        generation = Task {
            defer { generation = nil }
            do {
                let proposal = try await TripAgentPlanner.generate(
                    request, catalog: catalog.allExperiences, preferences: preferences, aiService: aiService
                )
                guard !Task.isCancelled, workspace.scope == TravelResearchService.shared.currentScope else { return }
                draft = proposal
                Haptics.selection()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, workspace.scope == TravelResearchService.shared.currentScope else { return }
                switch error as? TripAgentPlanner.Failure {
                case .noExperiences(let city):
                    self.error = String(
                        format: tripText("agent.noExperiences", "No matching catalog experiences in %@. Try another city or trip style."),
                        city
                    )
                case .noAvailableTimes:
                    self.error = tripText("agent.noTimes", "No catalog experiences fit this time window. Try a different date or trip style.")
                case .timeZoneUnavailable:
                    self.error = tripText("agent.noTimeZone", "Couldn’t find the local time zone. Try again online or choose another city.")
                case nil:
                    self.error = tripText("agent.failed", "Couldn’t prepare the draft. Try again.")
                }
            }
        }
    }

    private func save(_ proposal: TripProposal) {
        guard !didSave, workspace.scope == TravelResearchService.shared.currentScope else { return }
        do {
            let saved = try workspace.applyTrip(proposal)
            didSave = true
            onSaved(saved)
            Haptics.notify(.success)
            dismiss()
        } catch {
            self.error = tripText("error.retry", "Open the latest plan and try again.")
        }
    }
}
