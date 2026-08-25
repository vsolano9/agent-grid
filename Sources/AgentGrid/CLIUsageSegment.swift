import SwiftUI

struct CLIUsageSegment: View {
    let snapshot: ProviderUsageSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Text(ProviderUsagePresentation.providerName(snapshot.provider))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let warning = ProviderUsagePresentation.warning(for: snapshot) {
                Image(systemName: warning.systemImage)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help(warning.accessibilityLabel)
                    .accessibilityLabel(warning.accessibilityLabel)
            }

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    ProviderUsageWindowRowView(row: row)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(ProviderUsagePresentation.providerName(snapshot.provider)) usage")
    }

    private var rows: [ProviderUsageRow] {
        ProviderUsagePresentation.rows(for: snapshot)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 6, alignment: .top),
            count: max(1, (rows.count + 1) / 2)
        )
    }

}

private struct ProviderUsageWindowRowView: View {
    let row: ProviderUsageRow

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            Text(row.label)
                .font(.system(size: 8))
                .foregroundStyle(row.isStale ? .tertiary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .layoutPriority(1)

            value
        }
        .frame(height: 11)
        .help(row.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    @ViewBuilder
    private var value: some View {
        if row.isLoading {
            Text("Loading")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        } else {
            Text(row.valueText)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(row.isStale || row.isUnavailable ? .secondary : .primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
