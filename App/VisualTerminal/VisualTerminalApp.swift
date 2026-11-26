// File: VisualTerminalApp.swift
import SwiftUI

@main
struct VisualTerminalApp: App {
    @State private var session = SessionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
        .defaultSize(width: 900, height: 600)
    }
}
