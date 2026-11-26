// File: RootView.swift
import SwiftUI

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .connected:
                WorkspaceView()
            default:
                ConnectView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
