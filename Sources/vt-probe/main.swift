// 測試 SSH 核心：vt-probe <host> <port> <user> <password> <指令> [--trust]
//   --trust：遇到沒看過的伺服器指紋時自動信任（只給測試用）
import Foundation
import VisualTerminalCore

let args = CommandLine.arguments
guard args.count >= 6 else {
    print("用法：vt-probe <host> <port> <user> <password> <指令> [--trust]")
    exit(2)
}
let autoTrust = args.contains("--trust")
let knownHostsURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vt-probe-known_hosts.json")
do {
    let conn = try await SSHConnection.connect(host: args[1], port: Int(args[2]) ?? 22, username: args[3], password: args[4],
                                               knownHosts: KnownHosts(url: knownHostsURL)) { info in
        print("第一次連到 \(info.host):\(info.port)，指紋 \(info.fingerprint)（\(info.keyType)）→ \(autoTrust ? "信任" : "拒絕")")
        return autoTrust
    }
    print("✅ 已登入 \(conn.username)@\(conn.host)")
    for try await event in conn.run(args[5]) {
        switch event {
        case .stdout(let s): print(s, terminator: "")
        case .stderr(let s): FileHandle.standardError.write(Data(("[stderr] " + s).utf8))
        case .exit(let c): print("[結束碼 \(c)]")
        }
    }
    await conn.close()
} catch {
    print("❌ \(error.localizedDescription)")
    exit(1)
}
