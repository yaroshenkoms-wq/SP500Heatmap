//
//  SP500HeatmapApp.swift
//  SP500Heatmap
//
//  Created by Maxim Yaroshenko on 11/6/26.
//

import SwiftUI

@main
struct SP500HeatmapApp: App {
    @AppStorage(AppLanguage.storageKey) private var language = ""

    var body: some Scene {
        WindowGroup {
            // Смена языка в приложении: новое окружение и пересборка всего дерева экранов.
            ContentView()
                .environment(\.locale, AppLanguage.locale)
                .environment(\.layoutDirection, AppLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
                .id(language)
        }
    }
}
