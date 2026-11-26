請寫 VisualTerminal 的第二個功能：連線後的「拼塊工作區」。使用者不用打指令，用點選拼塊組出管線（例如「容器日誌 → 搜尋 error → 計算行數」），執行後在下方看到像終端機一樣的輸出紀錄。

## 一、先修正上一階段的三個問題
1. **中文輸入法會打出全形字**：使用者用注音輸入時，主機會變成「１２７．０．０．１」、Port 變成 0。在 `SessionModel.connect()` 使用主機與帳號之前，先把全形 ASCII 字元（U+FF01～U+FF5E）轉成半形（減 0xFEE0）、全形空白 U+3000 轉成一般空白，再去掉頭尾空白。Port 欄位輸入的全形數字也要轉成半形後再解析。把轉換寫成一個函式 `func toHalfWidth(_ s: String) -> String`（放在 SessionModel.swift 檔案最上層）。
2. **Port 顯示成「2,222」**：指紋確認框中 `Text("…\(info.port)")` 會依地區格式加上千分位。所有顯示 port 的地方改用 `String(port)` 組字串，或用 `Text(verbatim:)`。
3. **結束碼顯示成「Optional(0)」**：這一階段會刪除 ConnectedView，新的輸出紀錄要正確顯示結束碼（見下）。

## 二、檔案
- 刪除 `ConnectedView.swift` 的內容，改成只留一行註解 `// 已由 WorkspaceView 取代`（不要在檔案中宣告任何型別）。
- `RootView.swift`：已連線時顯示 `WorkspaceView()`。
- `Blocks.swift`：拼塊的資料與指令組裝（**只用 Foundation 與 VisualTerminalCore，不可 import SwiftUI**，我會單獨測試它）。
- `WorkspaceModel.swift`：`@MainActor @Observable final class WorkspaceModel`。
- `WorkspaceView.swift`、`BlockPaletteView.swift`、`PipelineEditorView.swift`、`OutputLogView.swift`：畫面。

## 三、Blocks.swift（指令組裝規則必須完全照下面寫）
```swift
enum BlockKind: String, CaseIterable, Identifiable, Sendable {
    case containerList, containerLogs, readFile          // 資料來源
    case search, replace, head, tail, countLines, sort, unique   // 過濾與處理
    var id: String { rawValue }
    var isSource: Bool   // 前三種為 true
    var title: String    // 中文名稱：容器清單、容器日誌、讀取檔案、搜尋、取代、前幾行、後幾行、計算行數、排序、去除重複
    var symbol: String   // SF Symbol 名稱，自行選擇
    var summary: String  // 一句話說明，例如「列出伺服器上的 docker 容器」
}

struct Block: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: BlockKind
    // 參數（各種拼塊用到的欄位，未用到的維持預設值）
    var includeStopped = true          // 容器清單：包含已停止的容器
    var columns: [ContainerColumn] = [.name, .status]   // 容器清單：要顯示的欄位
    var container = ""                 // 容器日誌：容器名稱
    var path = ""                      // 讀取檔案：檔案路徑
    var text = ""                      // 搜尋：要找的文字；取代：要被取代的文字
    var replacement = ""               // 取代：取代成的文字
    var ignoreCase = true              // 搜尋：不分大小寫
    var invert = false                 // 搜尋：反向（排除含有這段文字的行）
    var useRegex = false               // 搜尋：使用正規表示式
    var count = 10                     // 前幾行、後幾行、容器日誌的行數（容器日誌預設 100，在建立時設定）
    var reverse = false                // 排序：由大到小
    var numeric = false                // 排序：依數字大小
    init(kind: BlockKind)              // 產生新的 UUID；kind == .containerLogs 時 count = 100
    var command: String? { get }       // 這一塊的指令；參數不完整時回傳 nil
}

enum ContainerColumn: String, CaseIterable, Identifiable, Sendable {
    case name, image, status, ports
    var id: String { rawValue }
    var title: String      // 名稱、映像、狀態、Port
    var template: String   // {{.Names}}、{{.Image}}、{{.Status}}、{{.Ports}}
}

/// 整條管線的指令：第一塊必須是資料來源、其餘都不是資料來源，且每一塊的 command 都不是 nil，
/// 才回傳各塊 command 用 " | " 連接的結果；否則回傳 nil。
func pipelineCommand(_ blocks: [Block]) -> String?
```

**每一塊的 command（使用者輸入的文字一律經過 `ShellQuote.quote`，下面的 `q(x)` 代表 `ShellQuote.quote(x)`）：**

| 拼塊 | command | 參數不完整（回傳 nil） |
|---|---|---|
| 容器清單 | `docker ps` + （includeStopped 時加 ` -a`）+ ` --format ` + `q(各欄位 template 依 ContainerColumn.allCases 的順序、只取被選的、用 \t 連接)`。這裡的 `\t` 是反斜線加 t 兩個字元，docker 會把它轉成 Tab | columns 為空 |
| 容器日誌 | `docker logs --tail ` + count + ` ` + `q(container)` + ` 2>&1` | container 去掉空白後為空，或 count < 1 |
| 讀取檔案 | `cat ` + 路徑：path 以 `~/` 開頭時寫成 `~/` + `q(去掉 ~/ 之後的部分)`（讓遠端 shell 展開 ~），否則 `q(path)` | path 去掉空白後為空 |
| 搜尋 | `grep` + （ignoreCase 時 ` -i`）+ （invert 時 ` -v`）+ （useRegex 時 ` -E`，否則 ` -F`）+ ` -- ` + `q(text)` | text 為空 |
| 取代 | `sed ` + `q("s/" + escapeFind(text) + "/" + escapeReplacement(replacement) + "/g")` | text 為空 |
| 前幾行 | `head -n ` + count | count < 1 |
| 後幾行 | `tail -n ` + count | count < 1 |
| 計算行數 | `wc -l` | — |
| 排序 | `sort` + （reverse 時 ` -r`）+ （numeric 時 ` -n`） | — |
| 去除重複 | `sort -u` | — |

`escapeFind`：把 `\` `/` `.` `*` `[` `]` `^` `$` 每個前面加一個反斜線（讓 sed 把要找的文字當成一般文字）。
`escapeReplacement`：把 `\` `/` `&` 每個前面加一個反斜線。

範例：
- 容器清單（預設）→ `docker ps -a --format '{{.Names}}\t{{.Status}}'`
- 容器日誌（wms-cs-api、100）→ `docker logs --tail 100 wms-cs-api 2>&1`
- 搜尋（error、不分大小寫）→ `grep -i -F -- error`
- 管線 → `docker logs --tail 100 wms-cs-api 2>&1 | grep -i -F -- error | wc -l`

## 四、WorkspaceModel
```swift
@MainActor @Observable final class WorkspaceModel {
    init(connection: SSHConnection)
    var blocks: [Block] = [Block(kind: .containerList)]   // 預設放一塊「容器清單」
    var command: String? { pipelineCommand(blocks) }
    var containers: [String] = []          // 容器名稱（給「容器日誌」的下拉選單）
    var log: [LogEntry] = []               // 輸出紀錄（最新的在最後）
    var isRunning: Bool
    func add(_ kind: BlockKind)            // 資料來源：取代第 0 塊（若第 0 塊不是資料來源就插到最前面）；其他：加到最後
    func remove(_ id: UUID)                // 不可刪除唯一的資料來源以外的限制不用做，刪掉後 command 自然會變成 nil
    func move(_ id: UUID, up: Bool)        // 過濾拼塊上下移動，不可移到第 0 塊之前
    func loadContainers() async            // 執行 docker ps -a --format '{{.Names}}'，每行一個名稱
    func run()                             // 執行 command；執行中再按無效
    func stop()                            // 取消正在執行的 Task
    func clearLog()
}

struct LogEntry: Identifiable {
    let id: UUID
    let command: String
    let startedAt: Date
    var output: String = ""                // stdout 與 stderr 依收到的順序接在一起
    var exitCode: Int32?
    var stopped = false                    // 使用者按了停止
    var running = true
}
```
- `run()`：新增一筆 LogEntry，開一個 Task（存起來給 stop 用）執行 `connection.run(command)`，收到 stdout / stderr 都接到 output（output 超過 200,000 字元就不再增加，並在最後加上「…（輸出過長，已截斷）」），收到 `.exit` 記錄結束碼；結束時 running = false。出錯時把 `error.localizedDescription` 接到 output。
- `stop()`：取消 Task，該筆 stopped = true、running = false。
- WorkspaceView 出現時呼叫一次 `loadContainers()`。

## 五、畫面
**WorkspaceView**：`@State` 持有 `WorkspaceModel`（用 SessionModel 的 connection 建立）。
- 上方工具列：「已連線：username@host」與「中斷連線」按鈕。
- 主要區域 `HSplitView`（或 HStack）：左邊 BlockPaletteView（寬約 220），右邊上下分成 PipelineEditorView 與 OutputLogView（`VSplitView`）。

**BlockPaletteView**：兩個區塊「資料來源」與「過濾與處理」，列出每種拼塊的圖示、名稱、說明；點一下呼叫 `add`。

**PipelineEditorView**：
- 由上而下顯示每一塊（卡片樣式），卡片之間顯示一個向下箭頭表示資料往下傳。
- 每張卡片：圖示與名稱、參數控制項、右上角「上移」「下移」「刪除」按鈕（資料來源不顯示上移下移）。
- 參數控制項：容器清單 → Toggle「包含已停止的容器」與每個欄位的 Toggle；容器日誌 → 容器 Picker（選項來自 containers，旁邊有重新整理按鈕）與行數 Stepper／TextField；讀取檔案 → 路徑 TextField；搜尋 → 文字 TextField、Toggle「不分大小寫」「排除含有的行」「使用正規表示式」；取代 → 兩個 TextField「找」「取代成」；前幾行／後幾行 → 行數；排序 → Toggle「由大到小」「依數字大小」；計算行數、去除重複 → 只顯示說明。
- 下方「指令預覽」：用等寬字型顯示 command（可選取文字）；command 為 nil 時顯示「請完成拼塊設定」。旁邊「執行」按鈕（快捷鍵 ⌘↩）；執行中改顯示「停止」。

**OutputLogView**：像終端機的深色區塊（等寬字型），依序顯示每筆紀錄：
- 第一行 `$ 指令`（顏色較亮）。
- 輸出內容（可選取文字）。
- 最後一行狀態：執行中顯示 ProgressView 與「執行中…」；結束顯示「結束碼 0」（用 `String(code)`）；按過停止顯示「已停止」。
- 有新內容時自動捲到最下方；右上角「清除紀錄」按鈕。

【目前專案的檔案】
```swift
// File: ConnectView.swift
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

```swift
// File: ConnectedView.swift
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

```swift
// File: RootView.swift
// File: RootView.swift
import SwiftUI

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .connected:
                ConnectedView()
            default:
                ConnectView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
```

```swift
// File: SessionModel.swift
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
// File: VisualTerminalApp.swift
// File: VisualTerminalApp.swift
import SwiftUI

@main
struct VisualTerminalApp: App {
    @State private var session = SessionModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
        .defaultSize(width: 900, height: 600)
    }
}
```

【作答格式】
- 每個檔案一個 ```swift 程式碼區塊，區塊第一行寫 `// File: 檔名.swift`。
- 只輸出這次新增或修改的檔案，但每個輸出的檔案都必須是**完整內容**，不可省略（不要寫 `...` 或「其餘不變」）。
- 沒有輸出的檔案會保持原樣。
- 程式碼區塊之外可以有簡短說明。