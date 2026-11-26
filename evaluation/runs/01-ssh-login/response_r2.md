```swift
// File: SessionModel.swift
import Foundation
import VisualTerminalCore

struct RecentServer: Codable, Equatable, Hashable, Sendable {
    var host: String
    var port: Int
    var username: String
}

@MainActor
@Observable
final class SessionModel {
    enum State: Equatable {
        case disconnected, connecting, connected
    }

    var state: State = .disconnected
    var host = ""
    var port = 22
    var username = ""
    var password = ""
    var errorMessage: String?
    var pendingHostKey: HostKeyInfo?
    var connection: SSHConnection?
    var recentServers: [RecentServer] = []

    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
    private static let recentServersKey = "recentServers"

    init() {
        loadRecentServers()
    }

    var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && port > 0 && port <= 65535
            && state != .connecting
    }

    func connect() async {
        guard state != .connecting else { return }
        state = .connecting
        errorMessage = nil

        do {
            let conn = try await SSHConnection.connect(
                host: host.trimmingCharacters(in: .whitespaces),
                port: port,
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                onUnknownHost: { [weak self] info in
                    guard let self else { return false }
                    await MainActor.run { self.pendingHostKey = info }
                    return await withCheckedContinuation { cont in
                        Task { @MainActor in self.hostKeyContinuation = cont }
                    }
                }
            )
            connection = conn
            state = .connected
            addRecentServer(RecentServer(host: host.trimmingCharacters(in: .whitespaces),
                                         port: port,
                                         username: username.trimmingCharacters(in: .whitespaces)))
            password = ""
        } catch {
            state = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func answerHostKey(trust: Bool) {
        pendingHostKey = nil
        hostKeyContinuation?.resume(returning: trust)
        hostKeyContinuation = nil
    }

    func disconnect() async {
        await connection?.close()
        connection = nil
        state = .disconnected
    }

    private func addRecentServer(_ server: RecentServer) {
        recentServers.removeAll { $0 == server }
        recentServers.insert(server, at: 0)
        if recentServers.count > 5 {
            recentServers = Array(recentServers.prefix(5))
        }
        saveRecentServers()
    }

    private func loadRecentServers() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentServersKey),
              let list = try? JSONDecoder().decode([RecentServer].self, from: data) else { return }
        recentServers = list
    }

    private func saveRecentServers() {
        if let data = try? JSONEncoder().encode(recentServers) {
            UserDefaults.standard.set(data, forKey: Self.recentServersKey)
        }
    }
}
```

```swift
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
                        set: { session.port = Int($0.filter(\.isNumber)) ?? 0 }
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
                                Text(":\(server.port)")
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
                主機：\(info.host):\(info.port)
                金鑰類型：\(info.keyType)
                指紋：\(info.fingerprint)

                請確認指紋與伺服器管理員提供的相同。
                """)
            }
        }
    }
}
```

修正方式：`RecentServer` 加上 `Hashable`（它已有 `Equatable`，加一個 conformance 即可），`ForEach(id: \.self)` 即可使用。