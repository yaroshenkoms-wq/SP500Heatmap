import SwiftUI

/// Кнопка «Follow live» на карте индекса: запускает Live Activity «Market session» для этого индекса.
struct LiveFollowButton: View {
    let sectors: [Sector]
    @EnvironmentObject private var indexStore: IndexStore
    @ObservedObject private var manager = LiveActivityManager.shared
    @State private var showInfo = false

    private var following: Bool { manager.isRunning && manager.indexId == indexStore.selectedId }

    var body: some View {
        Button {
            if following {
                Task { await manager.stop() }
            } else if manager.areActivitiesEnabled {
                let companies = sectors.flatMap { $0.subsectors.flatMap { $0.companies } }
                let id = indexStore.selectedId, name = indexStore.current.name
                Task { await manager.start(indexId: id, name: name, companies: companies) }
            }
            showInfo = !manager.areActivitiesEnabled
        } label: {
            Image(systemName: following ? "dot.radiowaves.left.and.right.slash" : "dot.radiowaves.left.and.right")
                .font(.subheadline)
                .foregroundColor(following ? Theme.gold : Theme.text)
                .frame(width: 34, height: 34)
                .outlinedControl()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(following ? "Stop following" : "Follow live"))
        .alert("Live Activities are off", isPresented: $showInfo) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Live Activities for this app in iOS Settings.")
        }
    }
}
