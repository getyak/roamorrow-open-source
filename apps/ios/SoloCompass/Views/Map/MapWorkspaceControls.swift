import SwiftUI

/// Small map-owned controls. The host owns presentation, conversations and
/// external work; this view only changes deterministic map browsing state.
@MainActor
struct MapWorkspaceControls<Context: View>: View {
    @Bindable var viewModel: MapViewModel
    let context: Context
    var sourceLabel: String? = nil
    var onReturnToConversation: (() -> Void)? = nil
    var onAskSelected: ((Experience) -> Void)? = nil
    var onOpenSavedList: (() -> Void)? = nil
    var onOpenFootprints: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    context.companionGlass(in: Capsule())
                    modeSelector.padding(2).companionGlass(in: Capsule())
                }
            } else {
                HStack(spacing: 2) {
                    context
                    Divider().frame(height: 15).accessibilityHidden(true)
                    modeSelector
                        .layoutPriority(1)
                }
                .padding(2)
                .companionGlass(in: Capsule())
            }

            HStack(spacing: 8) { savedControls }

            if let sourceLabel, let onReturnToConversation {
                Button(action: onReturnToConversation) {
                    HStack(spacing: 8) {
                        Text(sourceLabel).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        Spacer(minLength: 4)
                        Label(localized("map.workspace.source.return"), systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .companionGlass(in: Capsule())
                .accessibilityLabel(sourceLabel + ", " + localized("map.workspace.source.return"))
                .accessibilityIdentifier("map.workspace.source.return")
            }

            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { actionControls }
            } else {
                HStack(spacing: 8) { actionControls }
            }
        }
        .foregroundStyle(CompanionHomeStyle.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.workspace.controls")
    }

    private var modeSelector: some View {
        HStack(spacing: 2) {
            modeButton(.nearby, key: "map.workspace.nearby")
            modeButton(.saved, key: "map.workspace.saved")
            if let onOpenFootprints {
                selectorButton(label: FootprintText.text("title"), selected: false,
                               identifier: "companion.map.footprints", action: onOpenFootprints)
            }
        }
    }

    @ViewBuilder private var savedControls: some View {
        if viewModel.mapBrowseMode == .saved {
            savedScopeMenu
            if let onOpenSavedList {
                Button(action: onOpenSavedList) {
                    Image(systemName: "list.bullet")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .companionGlass(in: Circle())
                .accessibilityLabel(localized("map.workspace.saved.list"))
                .accessibilityIdentifier("map.workspace.saved.list")
            }
        }
    }

    @ViewBuilder private var actionControls: some View {
        if let onAskSelected, let selected = viewModel.selectedExperience {
            Button { onAskSelected(selected) } label: {
                Label(localized("map.workspace.askSelected"), systemImage: "bubble.left")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .companionGlass(in: Capsule())
            .accessibilityIdentifier("map.workspace.askSelected")
        }
    }

    private func modeButton(_ mode: MapWorkspaceBrowseMode, key: String) -> some View {
        let selected = viewModel.mapBrowseMode == mode
        let showsResults = mode == .nearby && selected && viewModel.messageResultIDs != nil
        return selectorButton(label: localized(showsResults ? "map.workspace.results" : key), selected: selected,
                              identifier: "map.workspace.mode.\(mode.rawValue)", showsResults: showsResults) {
            viewModel.setMapBrowseMode(mode)
            if showsResults { viewModel.searchThisArea() }
        }
    }

    private func selectorButton(label: String, selected: Bool, identifier: String,
                                showsResults: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if showsResults { Image(systemName: "xmark.circle").accessibilityHidden(true) }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, typeSize.isAccessibilitySize ? 9 : 8)
            .frame(minWidth: 44, minHeight: 36)
            .background(selected ? CompanionHomeStyle.accent.opacity(0.14) : .clear, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(showsResults ? localized("map.workspace.results.clearHint") : "")
        .accessibilityIdentifier(identifier)
    }

    private var savedScopeMenu: some View {
        Menu {
            ForEach(MapWorkspaceFavoriteScope.allCases) { scope in
                Button {
                    viewModel.setMapFavoriteScope(scope)
                } label: {
                    if scope == viewModel.mapFavoriteScope {
                        Label(scopeLabel(scope), systemImage: "checkmark")
                    } else {
                        Text(scopeLabel(scope))
                    }
                }
            }
        } label: {
            Label(scopeLabel(viewModel.mapFavoriteScope), systemImage: "chevron.down")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .companionGlass(in: Capsule())
        .accessibilityIdentifier("map.workspace.saved.scope")
    }

    private func scopeLabel(_ scope: MapWorkspaceFavoriteScope) -> String {
        localized(scope == .currentCity ? "map.workspace.saved.currentCity" : "map.workspace.saved.all")
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "Map workspace control")
    }
}
