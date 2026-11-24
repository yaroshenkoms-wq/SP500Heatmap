//
//  SP500HeatmapApp.swift
//  SP500Heatmap
//
//  Created by Maxim Yaroshenko on 11/6/26.
//

import SwiftUI
import WidgetKit

@main
struct SP500HeatmapApp: App {
    @AppStorage(AppLanguage.storageKey) private var language = ""
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AlertManager.registerBackgroundTask()
        AppSettings.mirrorLanguage()
        Task { @MainActor in WatchSync.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            // Смена языка в приложении: новое окружение и пересборка всего дерева экранов.
            ContentView()
                .environment(\.locale, AppLanguage.locale)
                .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
                .id(language)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
                .onChange(of: language) { _, _ in
                    AppSettings.mirrorLanguage()
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .task {
                    PushManager.shared.start()
                    LiveActivityManager.shared.startObservingTokens()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AlertManager.scheduleRefresh() }
            if phase == .active {
                Task {
                    await PushManager.shared.refresh()
                    await LiveActivityManager.shared.syncAutoStart()
                }
            }
        }
    }
}
