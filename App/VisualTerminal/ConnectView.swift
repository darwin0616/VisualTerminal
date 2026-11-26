// File: ConnectView.swift
import SwiftUI
import VisualTerminalCore

struct ConnectView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Text("連線到伺服器")
                .font(.title2.bold())

            Form {
                Section("連線資訊") {
                    TextField("主機（IP 或網域）", text: Bindable(session).host)
                    TextField("Port", text: Binding(
                        get: { String(session.port) },
                        set: { session.port = Int(toHalfWidth($0).filter(\.isNumber)) ?? 0 }
                    ))
                    .frame(maxWidth: 120)
                    TextField("帳號", text: Bindable(session).username)
                    SecureField("密碼", text: Bindable(session).password)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)

            if let errorMessage = session.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button(action: { Task { await session.connect() } }) {
                if session.state == .connecting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 80)
                } else {
                    Text("連線")
                }
            }
            .disabled(!session.canConnect)
            .keyboardShortcut(.return, modifiers: [])

            if !session.recentServers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近的伺服器")
                        .font(.headline)
                    ForEach(session.recentServers, id: \.self) { server in
                        Button(action: {
                            session.host = server.host
                            session.port = server.port
                            session.username = server.username
                            session.password = ""
                        }) {
                            HStack {
                                Text("\(server.username)@\(server.host)")
                                Spacer()
                                Text(verbatim: ":\(server.port)")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: 420, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onSubmit {
            if session.canConnect { Task { await session.connect() } }
        }
        .alert("第一次連到這台伺服器", isPresented: Binding(
            get: { session.pendingHostKey != nil },
            set: { _ in }
        )) {
            Button("信任並連線") { session.answerHostKey(trust: true) }
            Button("取消", role: .cancel) { session.answerHostKey(trust: false) }
        } message: {
            if let info = session.pendingHostKey {
                Text("""
                主機：\(info.host):\(String(info.port))
                金鑰類型：\(info.keyType)
                指紋：\(info.fingerprint)

                請確認指紋與伺服器管理員提供的相同。
                """)
            }
        }
    }
}
