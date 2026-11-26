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
