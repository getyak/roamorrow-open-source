import SwiftUI

enum CompanionPrimaryTab: String, CaseIterable, Identifiable {
    case now, nearby, itinerary, me
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return companionText("companion.tab.conversation", "对话")
        case .nearby: return companionText("companion.tab.map", "地图")
        case .itinerary: return companionText("companion.tab.itinerary", "行程")
        case .me: return companionText("companion.tab.me", "我的")
        }
    }
    var symbol: String {
        switch self {
        case .now: return "bubble.left"
        case .nearby: return "map"
        case .itinerary: return "calendar"
        case .me: return "person.crop.circle"
        }
    }
}

/// Navigation stays separate from the composer and never owns conversation state.
@MainActor
struct CompanionNavigationBar: View {
    let selection: CompanionPrimaryTab
    let onSelect: (CompanionPrimaryTab) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CompanionPrimaryTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    guard !selected else { return }
                    Haptics.selection()
                    onSelect(tab)
                } label: {
                    Image(systemName: tab.symbol)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? CompanionHomeStyle.ink : CompanionHomeStyle.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: typeSize.isAccessibilitySize ? 44 : 38)
                    .background(CompanionHomeStyle.accent.opacity(selected ? 0.14 : 0), in: Capsule())
                    .frame(minWidth: 44, minHeight: typeSize.isAccessibilitySize ? 48 : 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityShowsLargeContentViewer { Label(tab.title, systemImage: tab.symbol) }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("companion.surface.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .companionGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(CompanionHomeStyle.line, lineWidth: 0.5))
        .frame(maxWidth: typeSize.isAccessibilitySize ? 260 : 226)
        .padding(.horizontal, 12)
        .padding(.top, 4).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.navigation")
    }
}
