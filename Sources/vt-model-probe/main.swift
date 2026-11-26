// 驗證 inkling 寫的 SessionModel（App/VisualTerminal/SessionModel.swift 的符號連結）對真實 SSH 伺服器的行為
import Foundation
import VisualTerminalCore

var failures = 0
@MainActor func check(_ ok: Bool, _ name: String) { print(ok ? "✅" : "❌", name); if !ok { failures += 1 } }

@MainActor func run() async {
    // 測試用：清掉 app 記住的指紋，讓「第一次連線」的流程會出現
    try? KnownHosts().forget(host: "127.0.0.1", port: 2222)
    let m = SessionModel()
    m.host = "127.0.0.1"; m.port = 2222; m.username = "tester"; m.password = "wrong"

    // 1. 指紋確認 → 取消
    let t1 = Task { await m.connect() }
    while m.pendingHostKey == nil { try? await Task.sleep(for: .milliseconds(50)) }
    check(m.state == .connecting && m.pendingHostKey?.fingerprint.hasPrefix("SHA256:") == true, "第一次連線出現指紋確認（\(m.pendingHostKey?.fingerprint ?? "")）")
    try? await Task.sleep(for: .milliseconds(200))
    m.answerHostKey(trust: false)
    await t1.value
    check(m.state == .disconnected && (m.errorMessage ?? "").contains("拒絕"), "按取消 → 未連線，訊息：\(m.errorMessage ?? "nil")")

    // 2. 信任 + 錯誤密碼
    let t2 = Task { await m.connect() }
    while m.pendingHostKey == nil { try? await Task.sleep(for: .milliseconds(50)) }
    m.answerHostKey(trust: true)
    await t2.value
    check(m.state == .disconnected && m.errorMessage == "帳號或密碼錯誤", "信任後密碼錯誤 → 訊息：\(m.errorMessage ?? "nil")")

    // 3. 正確密碼（指紋已記住，不應再問）
    m.password = "tester"
    let t3 = Task { await m.connect() }
    var asked = false
    for _ in 0..<100 { if m.pendingHostKey != nil { asked = true; break }; if m.state != .connecting { break }; try? await Task.sleep(for: .milliseconds(50)) }
    await t3.value
    check(!asked, "指紋已記住，第二次不再詢問")
    check(m.state == .connected && m.connection != nil, "正確密碼 → 已連線")
    check(m.password.isEmpty, "連線成功後清空密碼")
    check(m.recentServers.first == RecentServer(host: "127.0.0.1", port: 2222, username: "tester"), "加入最近的伺服器")
    if let c = m.connection, let r = try? await c.runCollecting("uname -s") {
        check(r.stdout.contains("Linux") && r.exitCode == 0, "連線可執行指令：\(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    await m.disconnect()
    check(m.state == .disconnected && m.connection == nil, "中斷連線")

    // 4. 最近的伺服器存在 UserDefaults（重新建立 model 也讀得到），且沒有存密碼
    let m2 = SessionModel()
    check(m2.recentServers.first?.host == "127.0.0.1", "重新開啟後仍記得最近的伺服器")
    let raw = UserDefaults.standard.data(forKey: "recentServers").map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(!raw.contains("tester\",\"password") && !raw.lowercased().contains("password"), "UserDefaults 裡沒有密碼：\(raw)")

    // 5. 連不到的主機
    m2.host = "127.0.0.1"; m2.port = 2299; m2.username = "x"; m2.password = "y"
    await m2.connect()
    check(m2.state == .disconnected && (m2.errorMessage ?? "").contains("無法連線"), "連不到的 port → \(m2.errorMessage ?? "nil")")
    print(failures == 0 ? "全部通過" : "失敗 \(failures) 項")
}
await run()
