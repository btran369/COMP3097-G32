//
//  COMP3097_G32_iOSApp.swift
//  COMP3097-G32-iOS
//
//  Created by Vu.Quan.Tran on 2026-02-12.
//

import SwiftUI
import SwiftData

@main
struct COMP3097_G32_iOSApp: App {
    
    let container: ModelContainer = {
        let schema = Schema([DBCategory.self, DBProduct.self, DBShoppingList.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [config])
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)   // Injects context into the entire SwiftUI environment
    }
}
