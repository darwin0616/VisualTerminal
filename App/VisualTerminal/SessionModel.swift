// File: SessionModel.swift
import Foundation
import VisualTerminalCore

func toHalfWidth(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count)
    for ch in s {
        let scalar = ch.unicodeScalars.first!
        if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
            result.unicodeScalars.append(UnicodeScalar(scalar.value - 0xFEE0)!)
        } else if scalar.value == 0x3000 {
            result.append(" ")
        } else {
            result.append(ch)
        }
    }
    return result
}

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

        let cleanHost = toHalfWidth(host).trimmingCharacters(in: .whitespaces)
        let cleanUsername = toHalfWidth(username).trimmingCharacters(in: .whitespaces)

        do {
            let conn = try await SSHConnection.connect(
                host: cleanHost,
                port: port,
                username: cleanUsername,
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
            addRecentServer(RecentServer(host: cleanHost,
                                         port: port,
                                         username: cleanUsername))
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
