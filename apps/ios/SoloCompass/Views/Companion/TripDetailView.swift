import SwiftUI

func tripText(_ key: String, _ fallback: String) -> String {
    NSLocalizedString("trip.\(key)", value: fallback, comment: "Multi-city trip")
}

func tripDateLabel(_ day: TripDay, _ template: String = "MMMd") -> String {
    let zone = TimeZone(identifier: day.city.timezone) ?? .gmt
    guard let date = TripPlan.date(day.date, zone: zone) else { return day.date }
    let format = DateFormatter()
    format.timeZone = zone
    format.setLocalizedDateFormatFromTemplate(template)
    return format.string(from: date)
}

struct TripListRow: View {
    let record: TripRecord

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "suitcase.rolling")
                .foregroundStyle(CompanionHomeStyle.accent)
                .frame(width: 46, height: 50)
                .background(CompanionHomeStyle.incoming, in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.plan.title).font(.headline).foregroundStyle(CompanionHomeStyle.ink)
                Text(record.plan.cityRoute.joined(separator: " → ")).font(.subheadline)
                if let start = record.plan.days.first, let end = record.plan.days.last {
                    Text("\(tripDateLabel(start)) – \(tripDateLabel(end, "yMMMd"))")
                        .font(.caption)
                }
            }
            .foregroundStyle(CompanionHomeStyle.secondaryInk)
            Spacer(minLength: 0)
            if record.isExample { Text(tripText("example", "Sample")).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct TripDetailView: View {
    let workspace: TripWorkspace?
    let id: String
    private let previewRecord: TripRecord?
    private let service = TravelResearchService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: String?
    @State private var handbook = false
    @State private var sheet: Sheet?
    @State private var error: String?
    @State private var didUndo = false

    init(workspace: TripWorkspace, id: String) {
        self.workspace = workspace
        self.id = id
        self.previewRecord = nil
    }

    init(preview record: TripRecord) {
        self.workspace = nil
        self.id = record.id
        self.previewRecord = record
    }

    private enum Sheet: Identifiable {
        case place(TripPlaceTarget), proposal(TripProposal), muse, credit

        var id: String {
            switch self {
            case .place(let target): "place.\(target.id)"
            case .proposal: "proposal"
            case .muse: "muse"
            case .credit: "credit"
            }
        }
    }

    private var record: TripRecord? {
        if let previewRecord { return previewRecord }
        guard let workspace, workspace.scope == service.currentScope else { return nil }
        return workspace.trip(id)
    }

    private func selectedDay(in record: TripRecord) -> TripDay? {
        let initial = record.isExample && record.id == "example-japan" ? "2026-12-14" : nil
        let now = Date()
        return record.plan.days.first { $0.date == selection }
            ?? record.plan.days.first { $0.date == initial }
            ?? record.plan.days.first { TripPlan.formatter(TimeZone(identifier: $0.city.timezone) ?? .gmt).string(from: now) == $0.date }
            ?? record.plan.days.first
    }

    var body: some View {
        Group {
            if let record, let day = selectedDay(in: record) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        cover(record)
                        if previewRecord != nil {
                            Label(tripText("example.readOnly", "Sample itinerary · view only"), systemImage: "eye")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(CompanionHomeStyle.secondaryInk)
                                .accessibilityIdentifier("trip.example.readOnly")
                        }
                        controls
                        dateRail(record, day: day)
                        if let workspace, let summary = record.latestSummary, record.undo != nil {
                            HStack(alignment: .top, spacing: 12) {
                                Label(summary, systemImage: "checkmark.circle")
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button(tripText("undo", "Undo")) {
                                    mutate { try workspace.undoTrip(id, expectedVersion: record.version); didUndo = true }
                                }
                                .font(.footnote.bold())
                                .accessibilityIdentifier("trip.undo")
                            }
                            .padding(12)
                            .background(CompanionHomeStyle.outgoing, in: RoundedRectangle(cornerRadius: 14))
                        } else if didUndo {
                            Label(tripText("undone", "Previous plan restored"), systemImage: "arrow.uturn.backward")
                                .font(.footnote)
                                .accessibilityIdentifier("trip.undone")
                        }
                        if handbook { guide(record, day: day) } else { schedule(record, day: day) }
                    }
                    .padding(.horizontal, 19)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .accessibilityIdentifier("trip.detail")
                .sheet(item: $sheet) { destination in
                    if self.record != nil {
                        switch destination {
                        case .place(let target):
                            if previewRecord != nil {
                                previewPlace(target)
                            } else {
                                TripPlaceSheet(target: target, record: record, onAdd: { place, time in
                                    add(place, at: time, on: target.day, in: record)
                                }, onProposal: { proposal in
                                    sheet = .proposal(proposal)
                                })
                            }
                        case .proposal(let proposal):
                            if let workspace {
                                NavigationStack {
                                    TripProposalReview(proposal: proposal, prior: record.plan,
                                                       title: tripText("review", "Review changes")) {
                                        mutate {
                                            try workspace.applyTrip(proposal)
                                            didUndo = false
                                            sheet = nil
                                        }
                                    }
                                }
                            }
                        case .muse:
                            if let workspace {
                                TripMuseHandoffView(workspace: workspace, record: record) { _ in didUndo = false }
                            }
                        case .credit:
                            NavigationStack {
                                List {
                                    Link("Rainy street, Kyoto — Tom Maisey · CC BY 2.0",
                                         destination: URL(string: "https://commons.wikimedia.org/wiki/File:Rainy_street,_Kyoto_(16683855248).jpg")!)
                                }
                                .navigationTitle(tripText("photo", "Cover photo"))
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tripText("done", "Done")) { sheet = nil } } }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(tripText("unavailable", "Trip unavailable"), systemImage: "suitcase.rolling")
            }
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .background(CompanionHomeStyle.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let record, workspace != nil || record.id == "example-japan" {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if workspace != nil {
                            Button { sheet = .muse } label: {
                                Label(tripText("muse.adjust", "Plan with Muse"), systemImage: "arrow.up.right")
                            }
                            .accessibilityIdentifier("trip.muse")
                        }
                        if record.id == "example-japan" {
                            Button { sheet = .credit } label: { Label(tripText("photo", "Cover photo"), systemImage: "photo") }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(tripText("options", "Trip options"))
                    .accessibilityIdentifier("trip.options")
                }
            }
        }
        .onChange(of: service.currentScope) { _, _ in sheet = nil }
        .alert(tripText("error.save", "Couldn’t save"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(tripText("done", "Done")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func cover(_ record: TripRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let start = record.plan.days.first, let end = record.plan.days.last {
                Text("\(tripDateLabel(start)) – \(tripDateLabel(end, "yMMMd"))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.92))
            }
            Text(record.plan.title).font(.system(.largeTitle, design: .serif, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(record.plan.cityRoute.joined(separator: " → "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(19)
        .frame(maxWidth: .infinity, minHeight: 157, alignment: .bottomLeading)
        .foregroundStyle(.white)
        .background {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(colors: [Color(red: 0.30, green: 0.40, blue: 0.30), Color(red: 0.13, green: 0.23, blue: 0.19)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                    if record.id == "example-japan", let image = Self.kyotoCover {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                        LinearGradient(colors: [.black.opacity(0.07), .black.opacity(0.83)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .clipShape(.rect(cornerRadius: 22))
    }

    static let kyotoCover = Bundle.main.url(forResource: "TripCoverKyoto", withExtension: "jpg")
        .flatMap { UIImage(contentsOfFile: $0.path) }

    private var controls: some View {
        HStack(spacing: 8) {
            sectionButton(tripText("schedule", "Schedule"), guide: false)
            sectionButton(tripText("handbook", "Handbook"), guide: true)
            Spacer(minLength: 0)
        }
    }

    private func sectionButton(_ title: String, guide: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { handbook = guide }
        } label: {
            Text(title).font(.subheadline.weight(handbook == guide ? .bold : .medium))
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .background(handbook == guide ? CompanionHomeStyle.outgoing : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(handbook == guide ? .isSelected : [])
        .accessibilityIdentifier(guide ? "trip.handbook" : "trip.schedule")
    }

    private func dateRail(_ record: TripRecord, day: TripDay) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(record.plan.days) { date in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.19)) { selection = date.id }
                        } label: {
                            VStack(spacing: 5) {
                                Text(tripDateLabel(date, "Md")).font(.subheadline.weight(.semibold)).monospacedDigit()
                                Text(date.city.name).font(.caption2).lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .frame(minWidth: 61, minHeight: 57)
                            .foregroundStyle(day.id == date.id ? CompanionHomeStyle.paper : CompanionHomeStyle.ink)
                            .background(day.id == date.id ? CompanionHomeStyle.ink : CompanionHomeStyle.incoming, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .id(date.id)
                        .accessibilityAddTraits(day.id == date.id ? .isSelected : [])
                        .accessibilityIdentifier("trip.day.\(date.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(day.id, anchor: .center) }
            .onChange(of: day.id) { _, new in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.19)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func schedule(_ record: TripRecord, day: TripDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.city.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(tripDateLabel(day, "EEEE")).font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk)
            }
            .padding(.bottom, 5)
            if day.stops.isEmpty {
                Text(tripText("day.empty", "Room for something good. Add a place from your handbook."))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk).padding(.vertical, 18)
            }
            ForEach(day.stops.sorted(by: { $0.time < $1.time })) { stop in
                Button {
                    sheet = .place(.init(day: day, stop: stop))
                } label: {
                    item(symbol: stop.locked ? "lock" : stop.activity.symbol, title: stop.title,
                         subtitle: stop.locked ? tripText("locked", "Locked") : duration(stop.durationMinutes),
                         time: stop.time)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trip.stop.\(stop.id)")
                Divider().overlay(CompanionHomeStyle.line)
            }
            #if DEBUG
            if workspace != nil, record.isExample, let stop = day.stops.first(where: { $0.id == "jp-river" }),
               let proposal = TripAdviser.indoorAlternative(to: stop, day: day, in: record,
                    summary: tripText("rain.demo.summary", "Rain practice: move the walk and use a saved indoor stop.")) {
                Button { sheet = .proposal(proposal) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "cloud.rain")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tripText("rain.demo", "Practice a rain adjustment")).font(.subheadline.bold())
                            Text(tripText("rain.demo.note", "Simulated forecast · see what would move"))
                                .font(.caption).foregroundStyle(CompanionHomeStyle.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.footnote.weight(.semibold))
                    }
                    .padding(12)
                    .frame(minHeight: 50)
                    .background(CompanionHomeStyle.incoming, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.top, 13)
                .accessibilityIdentifier("trip.rain.demo")
            }
            #endif
        }
    }

    private func guide(_ record: TripRecord, day: TripDay) -> some View {
        let places = record.plan.handbook.filter { $0.cityCode == day.city.code }
        return VStack(alignment: .leading, spacing: 0) {
            Text(day.city.name).font(.title2.bold()).accessibilityAddTraits(.isHeader).padding(.bottom, 5)
            if places.isEmpty {
                Text(tripText("guide.empty", "No saved places for this city yet."))
                    .font(.subheadline).foregroundStyle(CompanionHomeStyle.secondaryInk).padding(.vertical, 18)
            }
            ForEach(places) { entry in
                Button {
                    sheet = .place(.init(day: day, guide: entry))
                } label: {
                    item(symbol: entry.activity.symbol, title: entry.title,
                         subtitle: record.plan.plannedChanges[entry.id] == nil ? duration(entry.durationMinutes) : tripText("guide.scheduled", "On the schedule"),
                         time: nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trip.guide.\(entry.id)")
                Divider().overlay(CompanionHomeStyle.line)
            }
        }
    }

    private func item(symbol: String, title: String, subtitle: String, time: String?) -> some View {
        HStack(spacing: 12) {
            if let time { Text(time).font(.footnote.monospacedDigit()).frame(minWidth: 42, alignment: .leading) }
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .frame(width: 32, height: 32)
                .background(CompanionHomeStyle.incoming, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(CompanionHomeStyle.secondaryInk)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                .foregroundStyle(CompanionHomeStyle.secondaryInk).accessibilityHidden(true)
        }
        .padding(.vertical, 9)
        .frame(minHeight: 53)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func previewPlace(_ target: TripPlaceTarget) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(target.title).font(.system(.title, design: .serif, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text([target.day.city.name, target.stop?.time, target.stop.map { duration($0.durationMinutes) }
                          ?? target.guide.map { duration($0.durationMinutes) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(CompanionHomeStyle.secondaryInk)
                    if let note = target.note {
                        Text(note).font(.body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .background(CompanionHomeStyle.paper.ignoresSafeArea())
            .navigationTitle(tripText("example", "Sample"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tripText("done", "Done")) { sheet = nil }
                }
            }
        }
    }

    private func duration(_ minutes: Int) -> String { String(format: tripText("minutes", "%d min"), minutes) }

    private func add(_ entry: TripGuidePlace, at time: String, on day: TripDay, in record: TripRecord) {
        guard let workspace, record.plan.plannedChanges[entry.id] == nil,
              let dayIndex = record.plan.days.firstIndex(where: { $0.id == day.id }) else { return }
        var plan = record.plan
        plan.days[dayIndex].stops.append(entry.stop(at: time))
        mutate {
            try workspace.applyTrip(.init(tripId: record.id, baseVersion: record.version,
                summary: String(format: tripText("guide.added", "Added %@"), entry.title), plan: plan))
            didUndo = false
            handbook = false
            sheet = nil
        }
    }

    private func mutate(_ action: () throws -> Void) {
        guard record != nil else { return }
        do {
            try action()
            Haptics.notify(.success)
        } catch {
            self.error = tripText("error.retry", "Open the latest plan and try again.")
        }
    }
}
