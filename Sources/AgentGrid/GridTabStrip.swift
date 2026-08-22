import SwiftUI

struct GridTabStrip: View {
    let model: GridTabsModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let motion = Animation.easeOut(duration: 0.14)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(model.grids.enumerated()), id: \.element.id) { index, grid in
                        GridTabItem(
                            grid: grid,
                            shortcutNumber: index + 1,
                            isSelected: grid.id == model.selectedID,
                            canClose: model.canClose,
                            reduceMotion: reduceMotion,
                            select: { select(grid.id) },
                            close: { close(grid.id) }
                        )
                        .id(grid.id)
                        .transition(
                            .asymmetric(
                                insertion: .offset(x: 8).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                    }

                    addButton
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedID) { _, selectedID in
                withAnimation(reduceMotion ? nil : Self.motion) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
        .frame(height: 39)
        .background(Color(red: 0.075, green: 0.078, blue: 0.084))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent grids")
    }

    private var addButton: some View {
        Button(action: addGrid) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 39, height: 38)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.canAdd ? Color.white.opacity(0.72) : Color.white.opacity(0.28))
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
        }
        .disabled(!model.canAdd)
        .keyboardShortcut("t", modifiers: .command)
        .accessibilityLabel("New agent grid")
        .accessibilityHint(model.canAdd ? "Opens four new agent terminals" : "Six grids are already open")
        .help(model.canAdd ? "New Agent Grid (⌘T)" : "Maximum of six grids")
    }

    private func addGrid() {
        _ = withAnimation(reduceMotion ? nil : Self.motion) {
            model.addGrid()
        }
    }

    private func select(_ id: AgentGridTab.ID) {
        withAnimation(reduceMotion ? nil : Self.motion) {
            model.select(id)
        }
    }

    private func close(_ id: AgentGridTab.ID) {
        withAnimation(reduceMotion ? nil : Self.motion) {
            model.close(id)
        }
    }
}

private struct GridTabItem: View {
    let grid: AgentGridTab
    let shortcutNumber: Int
    let isSelected: Bool
    let canClose: Bool
    let reduceMotion: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    private static let motion = Animation.easeOut(duration: 0.14)

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                    Text(grid.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 13)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(
                KeyEquivalent(Character(String(shortcutNumber))),
                modifiers: .command
            )
            .accessibilityLabel(grid.title)
            .accessibilityHint("Shows this four-agent terminal grid")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            closeSlot
        }
        .frame(minWidth: 128, idealWidth: 156, maxWidth: 176)
        .frame(height: 38)
        .foregroundStyle(foregroundStyle)
        .background(backgroundStyle)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(red: 1, green: 0.62, blue: 0.25))
                .frame(height: 3)
                .opacity(isSelected ? 1 : 0)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.13))
                .frame(width: 1)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(reduceMotion ? nil : Self.motion, value: isSelected)
        .animation(reduceMotion ? nil : Self.motion, value: isHovered)
    }

    @ViewBuilder
    private var closeSlot: some View {
        if canClose {
            closeButton
        } else {
            Color.clear
                .frame(width: 32, height: 38)
                .accessibilityHidden(true)
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 32, height: 38)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(isSelected || isHovered ? 0.76 : 0))
        .allowsHitTesting(isSelected || isHovered)
        .accessibilityLabel("Close \(grid.title)")
        .accessibilityHint("Terminates this grid's four agent sessions")
        .help("Close \(grid.title)")
    }

    private var foregroundStyle: Color {
        if isSelected {
            return Color.white.opacity(0.92)
        }
        return Color.white.opacity(isHovered ? 0.78 : 0.58)
    }

    private var backgroundStyle: Color {
        if isSelected {
            return Color(red: 0.14, green: 0.145, blue: 0.155)
        }
        return Color.white.opacity(isHovered ? 0.055 : 0.02)
    }
}
