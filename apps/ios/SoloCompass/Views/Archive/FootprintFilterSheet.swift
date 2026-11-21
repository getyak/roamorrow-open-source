import SwiftUI

extension FootprintTimeFilter {
    var title: String {
        switch self {
        case .all: return FootprintText.text("filterAll")
        case .today: return FootprintText.text("today")
        case .week: return FootprintText.text("filterWeek")
        case .month: return FootprintText.text("filterMonth")
        case .custom(let dates):
            let calendar = Calendar.current
            let includesYear = !calendar.isDate(dates.lowerBound, equalTo: Date(), toGranularity: .year)
                || !calendar.isDate(dates.upperBound, equalTo: Date(), toGranularity: .year)
            let style: Date.FormatStyle = includesYear ? .dateTime.year().month(.abbreviated).day() : .dateTime.month(.abbreviated).day()
            let start = dates.lowerBound.formatted(style)
            return dates.lowerBound == dates.upperBound
                ? start : String.localizedStringWithFormat(FootprintText.text("timeRange"), start, dates.upperBound.formatted(style))
        }
    }
}

extension FootprintHistory {
    func cityName(_ id: String?) -> String? {
        if id == FootprintCity.unassignedID { return FootprintText.text("filterUnassigned") }
        return cities.first { $0.id == id }?.name
    }

    func title(for filter: FootprintFilter) -> String {
        guard let city = cityName(filter.cityID) else { return filter.time.title }
        return filter.time == .all ? city : [city, filter.time.title].joined(separator: " · ")
    }
}

struct FootprintFilterSheet: View {
    let history: FootprintHistory
    let apply: (FootprintFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft: FootprintFilter
    @State private var expandingRange: Bool

    init(history: FootprintHistory, filter: FootprintFilter, apply: @escaping (FootprintFilter) -> Void) {
        self.history = history
        self.apply = apply
        _draft = State(initialValue: filter)
        if case .custom = filter.time { _expandingRange = State(initialValue: true) }
        else { _expandingRange = State(initialValue: false) }
    }

    private var dates: Binding<ClosedRange<Date>> {
        Binding {
            if case .custom(let days) = draft.time {
                let start = min(max(days.lowerBound, history.domain.lowerBound), history.today)
                return start...min(max(days.upperBound, start), history.today)
            }
            return history.domain
        } set: { draft.time = .custom($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    timeSection
                    citySection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .navigationTitle(FootprintText.text("filterTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FootprintText.text("cancel")) { dismiss() }
                        .accessibilityIdentifier("footprints.filter.cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(FootprintText.text("filterReset")) {
                        draft = FootprintFilter()
                        expandingRange = false
                    }
                    .disabled(!draft.isActive)
                    .accessibilityIdentifier("footprints.filter.reset")
                }
            }
        }
        .tint(FootprintStyle.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading("filterTime")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 7) {
                timeChip(.all, id: "all")
                timeChip(.today, id: "today")
                timeChip(.week, id: "week")
                timeChip(.month, id: "month")
            }
            Button {
                if expandingRange {
                    expandingRange = false
                } else {
                    prepareCustomDates()
                    expandingRange = true
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "calendar")
                    Text(FootprintText.text("filterCustom")).fontWeight(.medium)
                    Spacer()
                    if case .custom = draft.time, !expandingRange {
                        Text(draft.time.title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: expandingRange ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 13))
            .accessibilityIdentifier("footprints.filter.custom")
            .disabled(history.days.isEmpty)

            if expandingRange {
                VStack(spacing: 10) {
                    FootprintRangeSlider(days: dates, domain: history.domain, calendar: history.calendar,
                                         activity: history.matchingDays(FootprintFilter(cityID: draft.cityID)))
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 9))
                        : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        dateField("filterFrom", id: "startDate", selection: Binding {
                            dates.wrappedValue.lowerBound
                        } set: {
                            let start = min(history.calendar.startOfDay(for: $0), dates.wrappedValue.upperBound)
                            dates.wrappedValue = start...dates.wrappedValue.upperBound
                        },
                        in: history.domain.lowerBound...dates.wrappedValue.upperBound)
                        dateField("filterTo", id: "endDate", selection: Binding {
                            dates.wrappedValue.upperBound
                        } set: {
                            let end = max(history.calendar.startOfDay(for: $0), dates.wrappedValue.lowerBound)
                            dates.wrappedValue = dates.wrappedValue.lowerBound...end
                        },
                        in: dates.wrappedValue.lowerBound...history.today)
                    }
                    .font(.footnote)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 15))
            }
        }
    }

    private func prepareCustomDates() {
        if case .custom = draft.time { return }
        let current = draft.time.days(endingOn: history.today, calendar: history.calendar)
        let earliest = max(current?.lowerBound ?? history.domain.lowerBound, history.domain.lowerBound)
        let latest = min(current?.upperBound ?? history.today, history.today)
        draft.time = .custom(min(earliest, latest)...latest)
    }

    private func dateField(_ key: String, id: String, selection: Binding<Date>, in bounds: ClosedRange<Date>) -> some View {
        let title = FootprintText.text(key)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            DatePicker(title, selection: selection, in: bounds, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityIdentifier("footprints.filter.\(id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var citySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading("filterCity")
            VStack(spacing: 0) {
                cityRow(FootprintText.text("filterAllCities"), id: nil)
                ForEach(history.cities) { city in
                    Divider().padding(.horizontal, 14)
                    cityRow(city.name, id: city.id)
                }
                if history.hasUnassigned {
                    Divider().padding(.horizontal, 14)
                    cityRow(FootprintText.text("filterUnassigned"), id: FootprintCity.unassignedID)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 15))
        }
    }

    private var actionBar: some View {
        let days = history.matchingDays(draft).count
        return Button {
            apply(draft)
            dismiss()
        } label: {
            HStack {
                Text(FootprintText.text("filterShowMap")).fontWeight(.semibold)
                Spacer()
                Text(days == 0 ? FootprintText.text("filterNoMatches")
                     : String.localizedStringWithFormat(FootprintText.text("filterDays"), days))
                    .font(.subheadline)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 49)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(FootprintStyle.accent, in: .rect(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("footprints.filter.apply")
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func heading(_ key: String) -> some View {
        Text(FootprintText.text(key))
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private func timeChip(_ period: FootprintTimeFilter, id: String) -> some View {
        let selected = draft.time == period
        return Button {
            draft.time = period
            expandingRange = false
        } label: {
            Text(period.title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? FootprintStyle.accent : Color.primary)
                .background(selected ? FootprintStyle.accent.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground),
                            in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("footprints.filter.time.\(id)")
    }

    private func cityRow(_ title: String, id: String?) -> some View {
        let selected = draft.cityID == id
        let count = history.matchingDays(FootprintFilter(time: draft.time, cityID: id)).count
        return Button { draft.cityID = id } label: {
            HStack(spacing: 12) {
                Text(title)
                Spacer()
                if count > 0 {
                    Text(String.localizedStringWithFormat(FootprintText.text("filterDays"), count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? FootprintStyle.accent : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("footprints.filter.city.\(id ?? "all")")
    }
}

private struct FootprintRangeSlider: View {
    @Binding var days: ClosedRange<Date>
    let domain: ClosedRange<Date>
    let calendar: Calendar
    let activity: [FootprintHistory.Day]
    @State private var dragging: Endpoint?
    @Environment(\.layoutDirection) private var layoutDirection

    private enum Endpoint { case start, end }
    private var dayCount: Int { max(0, offset(domain.upperBound)) }
    private let inset: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let span = max(1, proxy.size.width - inset * 2)
            let start = position(days.lowerBound, span: span)
            let end = position(days.upperBound, span: span)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawActivity(in: context, span: span, height: size.height)
                }
                Capsule().fill(.secondary.opacity(0.20))
                    .frame(width: span, height: 3)
                    .offset(x: inset, y: 39)
                Capsule().fill(FootprintStyle.accent)
                    .frame(width: max(2, abs(end - start)), height: 3)
                    .offset(x: min(start, end), y: 39)
                thumb(at: start)
                if end != start { thumb(at: end) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard dayCount > 0 else { return }
                    let coordinate = layoutDirection == .rightToLeft
                        ? span + inset - value.location.x : value.location.x - inset
                    let fraction = min(1, max(0, coordinate / span))
                    let target = Int((fraction * CGFloat(dayCount)).rounded())
                    let from = offset(days.lowerBound)
                    let to = offset(days.upperBound)
                    if dragging == nil {
                        if from == to {
                            if target == from { return }
                            dragging = target < from ? .start : .end
                        } else {
                            dragging = abs(target - from) < abs(target - to) ? .start : .end
                        }
                    }
                    if let dragging { set(dragging, to: target) }
                }
                .onEnded { _ in dragging = nil })
        }
        .frame(height: 59)
        .accessibilityHidden(true)
    }

    private func thumb(at x: CGFloat) -> some View {
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .overlay(Circle().strokeBorder(FootprintStyle.accent, lineWidth: 2))
            .frame(width: 19, height: 19)
            .shadow(color: FootprintStyle.accent.opacity(0.14), radius: 2, y: 1)
            .position(x: x, y: 40)
            .allowsHitTesting(false)
    }

    private func offset(_ day: Date) -> Int {
        calendar.dateComponents([.day], from: domain.lowerBound, to: day).day ?? 0
    }

    private func position(_ date: Date, span: CGFloat) -> CGFloat {
        let fraction = min(1, max(0, CGFloat(offset(date)) / CGFloat(max(dayCount, 1))))
        return inset + span * (layoutDirection == .rightToLeft ? 1 - fraction : fraction)
    }

    private func set(_ endpoint: Endpoint, to offset: Int) {
        guard let date = calendar.date(byAdding: .day, value: offset, to: domain.lowerBound) else { return }
        switch endpoint {
        case .start: days = min(date, days.upperBound)...days.upperBound
        case .end: days = days.lowerBound...max(date, days.lowerBound)
        }
    }

    private func drawActivity(in context: GraphicsContext, span: CGFloat, height: CGFloat) {
        let count = min(51, max(1, dayCount + 1))
        var amounts = Array(repeating: 0, count: count)
        for day in activity {
            let bucket = min(count - 1, max(0, offset(day.date) * count / max(1, dayCount + 1)))
            amounts[bucket] += day.entryCount
        }
        let maximum = max(1, amounts.max() ?? 0)
        let step = span / CGFloat(count)
        for (index, amount) in amounts.enumerated() where amount > 0 {
            let column = layoutDirection == .rightToLeft ? count - 1 - index : index
            let barHeight = 4 + 25 * sqrt(CGFloat(amount) / CGFloat(maximum))
            let x = inset + CGFloat(column) * step + step / 2
            let isSelected = (min(position(days.lowerBound, span: span), position(days.upperBound, span: span)) - step / 2 ...
                              max(position(days.lowerBound, span: span), position(days.upperBound, span: span)) + step / 2).contains(x)
            let width = min(7, step * 0.56)
            let rect = CGRect(x: x - width / 2, y: height - 25 - barHeight, width: width, height: barHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)),
                         with: .color(isSelected ? FootprintStyle.accent.opacity(0.35) : .secondary.opacity(0.20)))
        }
    }
}

struct FootprintHistoryJournal: View {
    let days: [FootprintHistory.Day]
    let scope: String
    var allowedEntryIDs: ((Date) -> Set<UUID>)?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: FootprintHistory.Day?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(days.reversed())) { day in
                        Button { selected = day } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(day.date.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated)))
                                        .fontWeight(.medium)
                                    Text(detail(for: day))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 45)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("footprints.history.day")
                    }
                } header: {
                    Text(scope).textCase(nil)
                }
            }
            .navigationTitle(FootprintText.text("mapJournal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FootprintText.text("done")) { dismiss() }
                }
            }
        }
        .sheet(item: $selected) { day in
            FootprintJournalView(date: day.date, fixedDay: true, allowedEntryIDs: allowedEntryIDs?(day.date))
        }
    }

    private func detail(for day: FootprintHistory.Day) -> String {
        let counts = [
            day.stops > 0 ? String.localizedStringWithFormat(FootprintText.text("visitCount"), day.stops) : nil,
            day.photos > 0 ? String.localizedStringWithFormat(FootprintText.text("photoCount"), day.photos) : nil
        ].compactMap { $0 }
        return counts.isEmpty ? FootprintText.text("filterTrackRecorded") : counts.joined(separator: " · ")
    }
}
