// 驗證 inkling 寫的 Blocks.swift 與 WorkspaceModel.swift（符號連結到 App/VisualTerminal/）
// 1. 指令逐字比對  2. 在測試 SSH 伺服器上實際執行（含惡意輸入）  3. 執行、停止與輸出截斷
import Foundation
import VisualTerminalCore

var failures = 0
var total = 0
@MainActor func check(_ ok: Bool, _ name: String) { total += 1; print(ok ? "✅" : "❌", name); if !ok { failures += 1 } }
@MainActor func expect(_ got: String?, _ want: String?, _ name: String) {
    check(got == want, "\(name)：\(got.map { "`\($0)`" } ?? "nil")" + (got == want ? "" : "（預期 \(want.map { "`\($0)`" } ?? "nil")）"))
}
func b(_ k: BlockKind, _ f: (inout Block) -> Void = { _ in }) -> Block { var x = Block(kind: k); f(&x); return x }

@MainActor func run() async {
    print("== 1. 指令逐字比對")
    expect(b(.containerList).command, "docker ps -a --format '{{.Names}}\\t{{.Status}}'", "容器清單（預設）")
    expect(b(.containerList) { $0.includeStopped = false; $0.columns = [.ports, .name] }.command,
           "docker ps --format '{{.Names}}\\t{{.Ports}}'", "容器清單（不含停止、欄位依固定順序）")
    expect(b(.containerList) { $0.columns = [] }.command, nil, "容器清單（沒選欄位）")
    expect(b(.containerLogs).count == 100 ? "100" : "\(b(.containerLogs).count)", "100", "容器日誌預設 100 行")
    expect(b(.containerLogs) { $0.container = "wms-cs-api" }.command, "docker logs --tail 100 wms-cs-api 2>&1", "容器日誌")
    expect(b(.containerLogs) { $0.container = "  " }.command, nil, "容器日誌（沒選容器）")
    expect(b(.containerLogs) { $0.container = "x"; $0.count = 0 }.command, nil, "容器日誌（行數 0）")
    expect(b(.readFile) { $0.path = "~/a b.log" }.command, "cat ~/'a b.log'", "讀取檔案（~ 與空白）")
    expect(b(.readFile) { $0.path = "/var/log/x.log" }.command, "cat /var/log/x.log", "讀取檔案（絕對路徑）")
    expect(b(.readFile).command, nil, "讀取檔案（沒填路徑）")
    expect(b(.search) { $0.text = "error" }.command, "grep -i -F -- error", "搜尋（預設）")
    expect(b(.search) { $0.text = "a|b"; $0.ignoreCase = false; $0.invert = true; $0.useRegex = true }.command,
           "grep -v -E -- 'a|b'", "搜尋（反向、正規表示式、分大小寫）")
    expect(b(.search).command, nil, "搜尋（沒填文字）")
    expect(b(.replace) { $0.text = "a.b/c"; $0.replacement = "&x" }.command, "sed 's/a\\.b\\/c/\\&x/g'", "取代（特殊字元）")
    expect(b(.replace).command, nil, "取代（沒填文字）")
    expect(b(.head) { $0.count = 5 }.command, "head -n 5", "前幾行")
    expect(b(.tail) { $0.count = 3 }.command, "tail -n 3", "後幾行")
    expect(b(.head) { $0.count = 0 }.command, nil, "前幾行（0）")
    expect(b(.countLines).command, "wc -l", "計算行數")
    expect(b(.sort) { $0.reverse = true; $0.numeric = true }.command, "sort -r -n", "排序（由大到小、數字）")
    expect(b(.unique).command, "sort -u", "去除重複")
    expect(pipelineCommand([b(.containerLogs) { $0.container = "wms-cs-api" }, b(.search) { $0.text = "error" }, b(.countLines)]),
           "docker logs --tail 100 wms-cs-api 2>&1 | grep -i -F -- error | wc -l", "管線")
    expect(pipelineCommand([b(.search) { $0.text = "x" }]), nil, "管線（沒有資料來源）")
    expect(pipelineCommand([b(.containerList), b(.readFile) { $0.path = "/a" }]), nil, "管線（兩個資料來源）")
    expect(pipelineCommand([b(.containerList), b(.search)]), nil, "管線（有拼塊參數不完整）")
    check(BlockKind.allCases.filter(\.isSource).count == 3, "資料來源恰好 3 種")
    for k in BlockKind.allCases { check(!k.title.isEmpty && !k.summary.isEmpty && !k.symbol.isEmpty, "\(k.rawValue) 有名稱、說明、圖示：\(k.title)") }

    print("\n== 2. 在測試伺服器上執行")
    guard let conn = try? await SSHConnection.connect(host: "127.0.0.1", port: 2222, username: "tester", password: "tester",
                                                      onUnknownHost: { _ in true }) else { check(false, "連線測試伺服器"); return }
    _ = try? await conn.runCollecting("rm -f /tmp/PWN; printf 'a.b/c\\naXb/c\\nError one\\nerror two\\nok\\nx'\"'\"'; touch /tmp/PWN; '\"'\"'\\n' > /tmp/vt-test.txt; printf 'hello\\n' > ~/'my file.txt'")
    func out(_ blocks: [Block]) async -> String {
        guard let cmd = pipelineCommand(blocks) else { return "（指令為 nil）" }
        return (try? await conn.runCollecting(cmd).stdout) ?? "（執行失敗）"
    }
    let file = b(.readFile) { $0.path = "/tmp/vt-test.txt" }
    let o1 = await out([file, b(.search) { $0.text = "error" }])
    check(o1 == "Error one\nerror two\n", "搜尋 error（不分大小寫）→ \(o1.debugDescription)")
    let o2 = await out([file, b(.search) { $0.text = "x'; touch /tmp/PWN; '" }])
    let pwn = (try? await conn.runCollecting("test -e /tmp/PWN && echo YES || echo NO").stdout) ?? ""
    check(o2.contains("touch /tmp/PWN") && pwn.hasPrefix("NO"), "惡意搜尋字串只被當成文字，沒有建立 /tmp/PWN（\(pwn.trimmingCharacters(in: .whitespacesAndNewlines))）")
    let o3 = await out([file, b(.replace) { $0.text = "a.b/c"; $0.replacement = "&x" }, b(.head) { $0.count = 2 }])
    check(o3 == "&x\naXb/c\n", "取代 a.b/c → &x（. 不當萬用字元）→ \(o3.debugDescription)")
    let o4 = await out([b(.readFile) { $0.path = "~/my file.txt" }])
    check(o4 == "hello\n", "讀取 ~/my file.txt → \(o4.debugDescription)")
    let o5 = await out([b(.containerList) { $0.columns = [.name] }, b(.search) { $0.text = "vt-sshd" }])
    check(o5.contains("vt-sshd"), "容器清單找得到 vt-sshd")
    let o6 = await out([b(.containerLogs) { $0.container = "vt-sshd"; $0.count = 500 }, b(.search) { $0.text = "Accepted password" }, b(.countLines)])
    check((Int(o6.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0, "容器日誌含 stderr（sshd 的登入紀錄）→ \(o6.trimmingCharacters(in: .whitespacesAndNewlines)) 行")
    let o7 = await out([file, b(.sort) { $0.reverse = true }, b(.head) { $0.count = 1 }])
    check(o7 == "x'; touch /tmp/PWN; '\n", "排序由大到小取第 1 行 → \(o7.debugDescription)")

    print("\n== 3. WorkspaceModel：執行、停止、截斷、容器清單")
    let m = WorkspaceModel(connection: conn)
    check(m.blocks.count == 1 && m.blocks[0].kind == .containerList, "預設有一塊容器清單")
    await m.loadContainers()
    check(m.containers.contains("vt-sshd"), "loadContainers 取得 \(m.containers.count) 個容器")
    m.add(.search); m.add(.readFile)
    check(m.blocks.first?.kind == .readFile && m.blocks.count == 2, "加入資料來源會取代第 0 塊")
    if let id = m.blocks.last?.id { m.move(id, up: true) }
    check(m.blocks.first?.kind == .readFile, "過濾拼塊不能移到資料來源之前")
    m.blocks[0].path = "/tmp/vt-test.txt"; m.blocks[1].text = "error"
    m.run()
    for _ in 0..<100 where m.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
    check(m.log.last?.output == "Error one\nerror two\n" && m.log.last?.exitCode == 0 && m.log.last?.running == false,
          "run() 輸出與結束碼 → \(m.log.last?.output.debugDescription ?? "nil") / \(String(describing: m.log.last?.exitCode))")
    m.blocks = [b(.readFile) { $0.path = "/dev/zero" }]
    m.run()
    try? await Task.sleep(for: .seconds(2))
    m.stop()
    try? await Task.sleep(for: .milliseconds(500))
    let last = m.log.last
    check(last?.stopped == true && last?.running == false && !m.isRunning, "stop() → 已停止")
    check((last?.output.count ?? 0) <= 200_100 && (last?.output.hasSuffix("…（輸出過長，已截斷）") ?? false),
          "輸出截斷在 20 萬字（\(last?.output.count ?? 0) 字）")
    m.clearLog()
    check(m.log.isEmpty, "clearLog()")
    _ = try? await conn.runCollecting("rm -f /tmp/vt-test.txt ~/'my file.txt'")
    await conn.close()
}
await run()
print("\n\(total - failures)/\(total) 通過")
