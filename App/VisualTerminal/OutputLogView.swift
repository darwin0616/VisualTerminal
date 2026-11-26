// File: OutputLogView.swift
import SwiftUI

struct OutputLogView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("輸出紀錄")
                    .font(.headline)
                Spacer()
                Button("清除紀錄") { model.clearLog() }
                    .disabled(model.log.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.log.isEmpty {
                            Text("尚無輸出紀錄")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(model.log) { entry in
                            LogEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.log.last?.output) { _, _ in
                    if let last = model.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding()
        .background(Color(red: 0.13, green: 0.13, blue: 0.15))
        .foregroundStyle(.white)
    }
}

private struct LogEntryView: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ " + entry.command)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.green)
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if entry.running {
                    ProgressView()
                        .controlSize(.small)
                    Text("執行中…")
                } else if entry.stopped {
                    Text("已停止")
                } else if let code = entry.exitCode {
                    Text("結束碼 " + String(code))
                } else {
                    Text("已結束")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
