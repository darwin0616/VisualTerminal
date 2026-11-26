# 階段 01：SSH 登入畫面

- 日期：2026-11-26
- 需求檔：[`steps/01-connect.md`](../steps/01-connect.md)（完整原文另存於 [`runs/01-ssh-login/request.md`](runs/01-ssh-login/request.md)）
- 結果：**3 輪編譯成功，實測 12/12 一次通過，功能回饋 0 次，約 12 分鐘**；實機操作另發現 3 個介面問題（全形輸入、Port 千分位、Optional 顯示）

## 要 inkling 做什麼

寫出 Mac app 的第一個畫面：輸入伺服器資訊並用 SSH 登入。需求分成五個檔案：

| 檔案 | 要求 |
|---|---|
| `VisualTerminalApp.swift` | `@main`；`@State` 持有 `SessionModel` 並用 `.environment` 傳下去；預設視窗 900×600 |
| `SessionModel.swift` | `@MainActor @Observable`；連線狀態（未連線／連線中／已連線）、表單欄位、錯誤訊息、待確認的伺服器指紋、最近的伺服器 |
| `ConnectView.swift` | 連線表單、連線按鈕、錯誤訊息、最近的伺服器清單、指紋確認對話框 |
| `ConnectedView.swift` | 暫時的測試畫面：顯示已連線、執行 `uname -a`、中斷連線 |
| `RootView.swift` | 依連線狀態切換畫面 |

需求中的重點細節：

1. **表單**：主機（IP 或網域）、Port（預設 22）、帳號、密碼（`SecureField`）。
2. **連線按鈕**：欄位未填齊或連線中時停用；連線中顯示轉圈；按 Enter 也能連線。
3. **第一次連線的伺服器指紋確認**：SSH 核心會呼叫 `onUnknownHost`，inkling 要讓它**暫停等待使用者在對話框按「信任並連線」或「取消」**（用 `withCheckedContinuation`，並注意切回 MainActor）。對話框要顯示主機、金鑰類型、指紋與提醒文字。
4. **成功**：切到已連線畫面、清空密碼、加入最近的伺服器（重複的移到最前面，最多 5 筆）。
5. **失敗**：回到未連線，用紅字顯示錯誤（帳號密碼錯誤、連不到、指紋改變等，訊息由 SSH 核心提供）。
6. **最近的伺服器**：存在 UserDefaults，只存主機、Port、帳號，**不存密碼**；點一下填回表單，密碼要重新輸入。
7. **測試畫面**：執行 `uname -a`，以等寬字型顯示輸出；可中斷連線。

SSH 本身（連線、密碼驗證、指紋紀錄、執行指令）由 Claude 先寫好並測試，API 說明放在 system prompt 中，inkling 只需要呼叫。

## 開發過程（真實紀錄）

| 輪次 | 輸出的檔案 | 耗時 | 產生 token | 讀入 token | 結果 |
|---|---|---|---|---|---|
| 0 | 全部 5 個檔案 | 421.6 秒 | 3505 | 2041 | 編譯失敗（1 個錯誤） |
| 1 | ConnectedView.swift | 128.2 秒 | 1173 | 4982 | 編譯失敗（1 個錯誤） |
| 2 | ConnectView.swift、SessionModel.swift | 195.7 秒 | 2108 | 5768 | **編譯成功** |

合計約 12 分鐘（10:23 開始、10:36 完成）。原始回覆在 [`runs/01-ssh-login/`](runs/01-ssh-login/)。

### 編譯錯誤原文

第 0 輪：

```
ConnectedView.swift:34: error: instance member 'monospaced' cannot be used on type 'Font'
    .font(.monospaced())
```

> 這個錯誤有一部分是 Claude 的需求寫得含糊：需求寫「用等寬字型（`.monospaced()`）」，inkling 照字面套進 `.font(...)`。修正後改用 `.font(.system(.body, design: .monospaced))`。

第 1 輪：

```
ConnectView.swift:50: error: generic struct 'ForEach' requires that 'RecentServer' conform to 'Hashable'
    ForEach(session.recentServers, id: \.self) { server in
```

> 自己宣告的 `RecentServer` 漏了 `Hashable`，第 2 輪補上。

兩個都是小錯誤，**沒有出現編造的 API、沒有 Swift 6 並行錯誤**。

## 測試了什麼

### 1. 程式碼審查（Claude 逐行閱讀，共 297 行）

| 需求 | 結果 |
|---|---|
| 表單四個欄位、Port 預設 22、密碼用 SecureField | ✅ |
| 按鈕停用條件、連線中轉圈、Enter 連線 | ✅（Port 欄位只接受數字） |
| 指紋確認：暫停等待使用者回答 | ✅ `withCheckedContinuation`，並以 `MainActor.run` / `Task { @MainActor in }` 切回主執行緒 |
| 指紋對話框內容（主機、金鑰類型、指紋、提醒） | ✅ |
| 成功後清空密碼、加入最近的伺服器（去重、最多 5 筆） | ✅ |
| 失敗顯示錯誤 | ✅ |
| 最近的伺服器存 UserDefaults、不存密碼、點擊填回 | ✅ |
| 測試畫面：`uname -a`、等寬字型、中斷連線 | ✅，但結束碼顯示有小 bug（見下） |
| 狀態管理只用 `@Observable` / `@Environment` / `@Bindable` | ✅ |
| 沒有空的事件處理、沒有用 `Any` 規避型別、沒有多做需求外的功能 | ✅ |

**找到的問題：**

- 小 bug：`ConnectedView` 顯示結束碼時寫成 `"[exit code: \(code)]"`，`code` 是 optional，畫面會出現 `[exit code: Optional(0)]`。只影響暫時的測試畫面，記錄後在下一階段一併回饋。
- 潛在風險（未觸發）：指紋確認時，continuation 是在另一個 `Task` 裡才存進 model；若使用者在那之前就按下按鈕，等待會卡住。實際上對話框出現需要時間，測試中沒有發生。

### 2. 功能驗證（接上真實 SSH 伺服器）

把 inkling 寫的 `SessionModel.swift`（以符號連結放進 [`Sources/vt-model-probe`](../Sources/vt-model-probe/)）和 SSH 核心一起編譯成指令列程式，連到本機的測試 SSH 伺服器（docker 容器，`127.0.0.1:2222`），模擬使用者操作：

| # | 情境 | 預期 | 結果 |
|---|---|---|---|
| 1 | 第一次連線 | 出現指紋確認（SHA256:…），狀態為連線中 | ✅ |
| 2 | 指紋確認按「取消」 | 不連線，顯示「已拒絕信任這台伺服器」 | ✅ |
| 3 | 按「信任」但密碼錯誤 | 不連線，顯示「帳號或密碼錯誤」 | ✅ |
| 4 | 再次連線 | 指紋已記住，不再詢問 | ✅ |
| 5 | 正確密碼 | 狀態變成已連線，取得連線物件 | ✅ |
| 6 | 連線成功後 | 密碼欄被清空 | ✅ |
| 7 | 連線成功後 | 伺服器加入最近清單最前面 | ✅ |
| 8 | 用這條連線執行 `uname -s` | 回傳 `Linux`、結束碼 0 | ✅ |
| 9 | 中斷連線 | 回到未連線，連線物件清除 | ✅ |
| 10 | 重新建立 model（模擬重開 app） | 仍記得最近的伺服器 | ✅ |
| 11 | 檢查 UserDefaults 內容 | 只有 host / port / username，沒有密碼 | ✅ `[{"port":2222,"host":"127.0.0.1","username":"tester"}]` |
| 12 | 連到沒有服務的 Port | 不連線，顯示「無法連線」 | ✅ |

**12/12 一次通過**，不需要任何功能回饋。

第 12 項的錯誤訊息原本是英文（`NIOConnectionError error 1`），這是 Claude 寫的 SSH 核心沒有翻譯，與 inkling 無關，已改成中文說明。

### 3. 實機操作（macOS UI 自動化 + 截圖）

用 XCUITest 實際操作 app 一遍並截圖（連線畫面 → 填寫 → 指紋確認 → 密碼錯誤 → 已連線 → `uname -a` → 中斷）。程式碼審查與功能驗證都沒抓到、實際點畫面才發現的問題：

| # | 問題 | 影響 | 原因 |
|---|---|---|---|
| A | **中文輸入法打出全形字**：用注音輸入時主機變成「１２７．０．０．１」、Port 變成 0，無法連線 | 中文使用者一定會遇到 | 欄位沒有把全形字轉成半形、也沒有提示 |
| B | **Port 顯示成「2,222」**：指紋確認框寫成「127.0.0.1:2,222」 | 顯示錯誤，容易誤會 | SwiftUI 的 `Text("…\(info.port)")` 會把整數依地區格式加千分位 |
| C | **結束碼顯示成「Optional(0)」** | 只影響暫時的測試畫面 | `code` 是 optional，直接放進字串 |

這三個問題會在下一階段一併回饋給 inkling。

> 截圖時的插曲：自動化打字同樣會經過中文輸入法，第一次跑出全形字；測試改成暫時切到 ABC 輸入法、結束後切回。

## 結論

| 指標 | inkling（本階段） | gemma4:12b（對照：iPhoneToolKits 登入畫面） |
|---|---|---|
| 編譯 | 3 輪成功，2 個小錯誤 | 2 輪成功 |
| 第一版功能 | **12/12** | 無法登入（2 個致命錯誤） |
| 功能回饋 | **0 次** | 4 次 |
| Swift 6 並行（等待使用者回答） | 一次寫對 | 反覆出錯 |
| 單輪耗時 | 2～7 分鐘 | 約 2～4 分鐘 |

inkling 在需求清楚的前提下，第一版就能寫出可用的程式，最大的代價是速度：單輪最長 7 分鐘。不過「編譯成功＋邏輯測試通過」仍不等於介面沒問題：中文輸入法、數字格式這類細節，要實際操作畫面才看得到。
