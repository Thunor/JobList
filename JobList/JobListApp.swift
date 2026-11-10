//
//  JobListApp.swift
//  JobList
//
//  Created by Eric Freitas on 11/6/26.
//

import SwiftUI

@main
struct JobListApp: App {
    @State private var store = JobStore()

    var body: some Scene {
        Window("JobList", id: "main") {
            ContentView()
                .environment(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { store.isImporterPresented = true }
                    .keyboardShortcut("o")
            }
        }
    }
}
