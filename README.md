# VisualTerminal

給終端機新手用的 Mac app：**不用背指令、不用逐字敲打**，用點選拼塊的方式組出指令，透過 SSH 在遠端伺服器執行。

- 不需要 AI 助手：拼塊組出來的指令是確定的，看得到、可以學。
- 先從 SSH 登入開始，接著是 docker 拼塊（查看容器），再用管線拼塊串接 `grep`、`cat`、`sed`… 擷取需要的資訊。
- 擷取到的結果可以：留在畫面上的輸出紀錄、存成 app 內的筆記、存回遠端伺服器的檔案（需確認）、把拼好的指令存起來下次一鍵執行。

> 開發中。目前完成：SSH 核心、SSH 登入畫面。

## 開發環境

| 項目 | 版本 |
|---|---|
| Swift | **6.4.2**（Swift 6 語言模式，`SWIFT_STRICT_CONCURRENCY: complete`） |
| Xcode | 27.2（27B52） |
| macOS（開發機） | 27.2.1，Apple M6 |
| 最低支援 | macOS 15 |
| UI | SwiftUI（`@Observable` 狀態管理） |
| 專案產生 | [xcodegen](https://github.com/yonaskolb/XcodeGen)（`App/project.yml`） |

## 使用到的套件

| 套件 | 版本 | 用途 |
|---|---|---|
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh)（Apple） | 0.15.2 | SSH 連線：密碼登入、伺服器指紋、執行指令 |
| [swift-nio](https://github.com/apple/swift-nio)（Apple） | 2.105.2 | SwiftNIO SSH 的網路底層 |
| swift-crypto、swift-atomics、swift-collections、swift-system、swift-asn1 | 見 `Package.resolved` | 以上兩者的相依套件，全部是 Apple 開源 |

**拼塊沒有用任何特殊套件**：拼塊是用 SwiftUI 自己做的「點選組裝」介面（點積木加入管線、下拉選單填參數），沒有使用 Blockly 或其他拖放函式庫。整個專案唯一的外部依賴是 SSH，因為 macOS 內建的 `ssh` 指令無法直接帶入密碼，所以改用 Apple 開源的 SwiftNIO SSH。

## 專案結構

```
VisualTerminal/
├── Package.swift
├── Sources/
│   ├── VisualTerminalCore/     SSH 核心（Claude 撰寫）
│   │   ├── SSHConnection.swift   連線、密碼登入、執行指令、即時輸出
│   │   ├── KnownHosts.swift      伺服器指紋紀錄（第一次確認、之後比對）
│   │   └── ShellQuote.swift      使用者輸入的引號處理，避免遠端指令注入
│   ├── vt-probe/               指令列工具：測試 SSH 核心
│   └── vt-model-probe/         指令列工具：拿 App 的 SessionModel 對真實伺服器驗證
├── Tests/VisualTerminalCoreTests/  引號處理與指紋紀錄的單元測試
├── App/                        Mac app（畫面由 inkling 撰寫）
│   ├── project.yml
│   └── VisualTerminal/
├── testserver/                 測試用 SSH 伺服器（docker 容器）
├── prompts/macos-v1.txt        給 inkling 的 system prompt（含 SSH 核心 API 說明）
├── steps/                      每一階段給 inkling 的需求
├── tools/ai_dev.py             inkling 開發迴圈（需求 → 編譯 → 錯誤回饋）
└── evaluation/                 inkling 開發能力評測紀錄
```

## 建置與測試

```bash
# SSH 核心
swift build
swift test

# 測試用 SSH 伺服器（只綁定本機 127.0.0.1:2222，帳號密碼 tester / tester）
docker build -t vt-sshd testserver
docker run -d --name vt-sshd -p 127.0.0.1:2222:22 -v /var/run/docker.sock:/var/run/docker.sock vt-sshd
.build/debug/vt-probe 127.0.0.1 2222 tester tester "docker ps" --trust

# Mac app
cd App && xcodegen generate
xcodebuild -project VisualTerminal.xcodeproj -scheme VisualTerminal -destination 'platform=macOS' build
```

## 安全設計

- **伺服器指紋**：第一次連線顯示 SHA256 指紋請使用者確認並記住；之後指紋不同就中止連線，避免連到冒充的伺服器。紀錄在 `~/Library/Application Support/VisualTerminal/known_hosts.json`。
- **密碼**：不寫入任何檔案或 UserDefaults；「最近的伺服器」只記主機、Port、帳號。
- **指令注入**：拼塊裡使用者輸入的文字一律經過 `ShellQuote.quote`，單元測試用 20 種刁鑽字串（`; rm -rf ~`、`$(…)`、反引號、引號…）交給真正的 shell 驗證，還原後都與原字串相同。

## 開發分工與 inkling 評測

這個專案同時用來評測本地模型 **inkling-2-mini**（Ollama）的開發能力：

- **Claude**（Claude Code）：SSH 核心、引號處理、需求撰寫、編譯回饋、程式碼審查、功能驗證。
- **inkling-2-mini**：畫面、拼塊、指令組裝、輸出紀錄。

評測方法與每一階段的完整紀錄（需求原文、每一輪的耗時與 token、編譯錯誤原文、原始回覆、實測項目）在 [`evaluation/`](evaluation/)。

## inkling 評測一覽

| 階段 | 要 inkling 做什麼 | 測試了什麼 | 編譯 | 實測結果 | 功能回饋 | 時間 | 紀錄 |
|---|---|---|---|---|---|---|---|
| 01 | **SSH 登入畫面**：連線表單（主機、Port、帳號、密碼）、第一次連線的指紋確認對話框（暫停等待使用者回答）、錯誤訊息、最近的伺服器（不存密碼）、連線後的 `uname -a` 測試畫面 | 程式碼逐行審查（10 項需求）；UI 自動化實際操作並截圖；接上真實 SSH 伺服器實測 12 項：指紋確認／取消／記住、密碼錯誤、成功連線、清空密碼、最近伺服器、執行指令、中斷、重開仍記得、不存密碼、連不到主機 | 3 輪（2 個小錯誤） | **12/12**；實機操作另發現 3 個介面問題（全形輸入、Port 千分位、Optional 顯示） | 0 次 | 約 12 分鐘 | [01-ssh-login.md](evaluation/01-ssh-login.md) |
