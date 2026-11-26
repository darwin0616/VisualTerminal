```swift
// File: ConnectedView.swift
import SwiftUI
import VisualTerminalCore

struct ConnectedView: View {
    @Environment(SessionModel.self) private var session
    @State private var testOutput = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("已連線：\(session.username)@\(session.host)")
                .font(.title2.bold())

            HStack {
                Button("測試：執行 uname -a") {
                    Task { await runTest() }
                }
                .disabled(isRunning)

                Button("中斷連線") {
                    Task { await session.disconnect() }
                }
                .buttonStyle(.bordered)
            }

            if isRunning {
                ProgressView()
            }

            if !testOutput.isEmpty {
                ScrollView {
                    Text(testOutput)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }

            Spacer()
        }
        .padding()
    }

    private func runTest() async {
        guard let conn = session.connection else { return }
        isRunning = true
        testOutput = ""
        defer { isRunning = false }
        do {
            let (out, err, code) = try await conn.runCollecting("uname -a")
            var text = out
            if !err.isEmpty { text += "\n[stderr]\n" + err }
            text += "\n[exit code: \(code)]"
            testOutput = text
        } catch {
            testOutput = "執行失敗：\(error.localizedDescription)"
        }
    }
}
```

只修正了 `.font(.monospaced())` 這一處，改用確定存在的 `.font(.system(.body, design: .monospaced))`。