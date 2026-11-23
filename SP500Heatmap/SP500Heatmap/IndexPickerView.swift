import SwiftUI

struct IndexPickerView: View {
    @ObservedObject var indexStore: IndexStore
    @Environment(\.dismiss) private var dismiss

    private func indices(in region: String) -> [IndexInfo] {
        indexStore.indices.filter { ($0.region ?? "") == region }
    }

    private var otherIndices: [IndexInfo] {
        indexStore.indices.filter { !IndexStore.regionOrder.contains($0.region ?? "") }
    }

    private func title(for region: String) -> LocalizedStringKey {
        switch region {
        case "americas": return "Americas"
        case "europe": return "Europe"
        case "asia_pacific": return "Asia-Pacific"
        default: return "Other"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(IndexStore.regionOrder, id: \.self) { region in
                    let items = indices(in: region)
                    if !items.isEmpty {
                        Section { rows(items) } header: { header(title(for: region)) }
                    }
                }
                if !otherIndices.isEmpty {
                    Section { rows(otherIndices) } header: { header("Other") }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Select index")
                        .font(Theme.serif(.title3))
                        .foregroundColor(Theme.text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(Theme.ui(.subheadline, weight: .medium))
                }
            }
            .themeNavBar()
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.ui(.caption, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundColor(Theme.muted)
    }

    @ViewBuilder
    private func rows(_ items: [IndexInfo]) -> some View {
        ForEach(items) { item in
            Button {
                indexStore.selectedId = item.id
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(item.flag).font(.title2)
                    Text(verbatim: item.name)
                        .font(Theme.ui(.body))
                        .foregroundColor(Theme.text)
                    Spacer()
                    if item.id == indexStore.selectedId {
                        Image(systemName: "checkmark").foregroundColor(Theme.gold)
                    }
                }
            }
            .listRowBackground(Theme.panel)
            .listRowSeparatorTint(Theme.line)
        }
    }
}
