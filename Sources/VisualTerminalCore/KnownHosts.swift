import CryptoKit
import Foundation

/// 伺服器指紋紀錄（類似 ~/.ssh/known_hosts）。第一次連線時由使用者確認，之後指紋改變就拒絕連線。
public struct HostKeyInfo: Sendable, Equatable {
    public let host: String
    public let port: Int
    /// OpenSSH 格式的公鑰，例如 "ssh-ed25519 AAAA…"
    public let openSSHKey: String
    /// 和 `ssh-keygen -lf` 相同格式的指紋：SHA256:…
    public var fingerprint: String { KnownHosts.fingerprint(openSSHKey) }
    public var keyType: String { String(openSSHKey.split(separator: " ").first ?? "") }
}

public enum HostKeyStatus: Sendable, Equatable {
    case trusted
    case unknown
    /// 指紋和上次記錄的不同：可能是伺服器重灌，也可能是有人冒充
    case changed(previous: String)
}

public final class KnownHosts: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var entries: [String: String]

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisualTerminal/known_hosts.json")
    }

    public init(url: URL = KnownHosts.defaultURL) {
        self.url = url
        entries = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func status(of info: HostKeyInfo) -> HostKeyStatus {
        lock.withLock {
            guard let saved = entries[Self.key(info.host, info.port)] else { return .unknown }
            return saved == info.openSSHKey ? .trusted : .changed(previous: Self.fingerprint(saved))
        }
    }

    public func trust(_ info: HostKeyInfo) throws {
        let data: Data = try lock.withLock {
            entries[Self.key(info.host, info.port)] = info.openSSHKey
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try enc.encode(entries)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func forget(host: String, port: Int) throws {
        let data: Data = try lock.withLock {
            entries[Self.key(host, port)] = nil
            return try JSONEncoder().encode(entries)
        }
        try data.write(to: url, options: .atomic)
    }

    public static func fingerprint(_ openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "（無法解析）" }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
