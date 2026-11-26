// File: WorkspaceView.swift
import SwiftUI
import VisualTerminalCore

struct WorkspaceView: View {
    @Environment(SessionModel.self) private var session
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                HSplitView {
                    BlockPaletteView(model: model)
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                    VSplitView {
                        PipelineEditorView(model: model)
                        OutputLogView(model: model)
                    }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil, let conn = session.connection {
                let m = WorkspaceModel(connection: conn)
                model = m
                Task { await m.loadContainers() }
            }
        }
    }
}
