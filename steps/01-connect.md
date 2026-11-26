請寫 VisualTerminal 的第一個功能：SSH 連線畫面。

## 檔案
- `VisualTerminalApp.swift`：`@main`，取代目前的同名檔案。一個 `WindowGroup`，`@State` 持有 `SessionModel` 並用 `.environment` 傳下去。`.defaultSize(width: 900, height: 600)`。
- `SessionModel.swift`：`@MainActor @Observable final class SessionModel`。
- `ConnectView.swift`：未連線時顯示。
- `ConnectedView.swift`：已連線時顯示（這一步只做簡單的測試畫面）。
- `RootView.swift`：依 `SessionModel.state` 顯示 ConnectView 或 ConnectedView。

## SessionModel
```swift
enum State: Equatable { case disconnected, connecting, connected }
var state: State
var host = "", port = 22, username = "", password = ""
var errorMessage: String?          // 連線失敗時顯示
var pendingHostKey: HostKeyInfo?    // 不為 nil 時，畫面要跳出確認信任的對話框
var connection: SSHConnection?
var recentServers: [RecentServer]   // 最近連過的伺服器（只存 host、port、username，不存密碼），存在 UserDefaults，最多 5 筆
func connect() async
func answerHostKey(trust: Bool)     // 使用者在對話框按「信任」或「取消」
func disconnect() async
```
- `connect()`：state 設成 `.connecting`、清掉 errorMessage，呼叫 `SSHConnection.connect`。`onUnknownHost` 要等使用者回答：把 info 放進 `pendingHostKey`，用 `withCheckedContinuation` 等 `answerHostKey(trust:)` 被呼叫後再回傳結果（continuation 存在 model 的屬性中；注意 onUnknownHost 不在 MainActor 上被呼叫，要切回 MainActor 設定屬性）。
- 成功：state = `.connected`，把這台伺服器加到 recentServers 最前面（重複的移掉），密碼欄清空。
- 失敗：state = `.disconnected`，errorMessage = `error.localizedDescription`。
- `disconnect()`：關閉連線，state = `.disconnected`。

## ConnectView
- 標題「連線到伺服器」，表單（`Form` + `.formStyle(.grouped)`）：主機（IP 或網域）、Port（數字，預設 22）、帳號、密碼（`SecureField`）。
- 「連線」按鈕：欄位未填齊或連線中時停用；連線中顯示 `ProgressView`。按 Enter 也能連線（`.onSubmit`）。
- errorMessage 不為 nil 時用紅色文字顯示。
- 下方「最近的伺服器」清單：點一下就把 host / port / username 填進表單（密碼要重新輸入）。
- `pendingHostKey` 不為 nil 時顯示 `.alert`：標題「第一次連到這台伺服器」，內容顯示主機、金鑰類型與指紋，並說明「請確認指紋與伺服器管理員提供的相同」；按鈕「信任並連線」與「取消」，呼叫 `answerHostKey(trust:)`。

## ConnectedView（這一步的暫時畫面）
- 顯示「已連線：username@host」與「中斷連線」按鈕。
- 一個「測試：執行 uname -a」按鈕，執行後用等寬字型（`.monospaced()`）顯示輸出；執行中顯示 ProgressView。
