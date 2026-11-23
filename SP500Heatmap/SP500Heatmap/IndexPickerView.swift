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
                        Section(title(for: region)) { rows(items) }
                    }
                }
                if !otherIndices.isEmpty {
                    Section("Other") { rows(otherIndices) }
                }
            }
            .navigationTitle("Select index")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                    Text(verbatim: item.name).foregroundColor(.primary)
                    Spacer()
                    if item.id == indexStore.selectedId {
                        Image(systemName: "checkmark").foregroundColor(.blue)
                    }
                }
            }
        }
    }
}
