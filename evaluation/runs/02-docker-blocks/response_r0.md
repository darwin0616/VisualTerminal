先修正 SessionModel（全形轉半形、Port 解析）與 ConnectView（Port 顯示），再新增拼塊工作區。

```swift
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
```

```swift
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
                        set: { session.port = Int(toHalfWidth($0).filter(\.isNumber)) ?? 0 }
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
                                Text(verbatim: ":\(server.port)")
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
                主機：\(info.host):\(String(info.port))
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
// 已由 WorkspaceView 取代
```

```swift
// File: RootView.swift
import SwiftUI

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .connected:
                WorkspaceView()
            default:
                ConnectView()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
```

```swift
// File: Blocks.swift
import Foundation
import VisualTerminalCore

enum BlockKind: String, CaseIterable, Identifiable, Sendable {
    case containerList, containerLogs, readFile
    case search, replace, head, tail, countLines, sort, unique

    var id: String { rawValue }

    var isSource: Bool {
        switch self {
        case .containerList, .containerLogs, .readFile: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .containerList: return "容器清單"
        case .containerLogs: return "容器日誌"
        case .readFile: return "讀取檔案"
        case .search: return "搜尋"
        case .replace: return "取代"
        case .head: return "前幾行"
        case .tail: return "後幾行"
        case .countLines: return "計算行數"
        case .sort: return "排序"
        case .unique: return "去除重複"
        }
    }

    var symbol: String {
        switch self {
        case .containerList: return "shippingbox"
        case .containerLogs: return "doc.text"
        case .readFile: return "folder"
        case .search: return "magnifyingglass"
        case .replace: return "text.badge.checkmark"
        case .head: return "arrow.up.to.line"
        case .tail: return "arrow.down.to.line"
        case .countLines: return "number"
        case .sort: return "arrow.up.arrow.down"
        case .unique: return "list.remove"
        }
    }

    var summary: String {
        switch self {
        case .containerList: return "列出伺服器上的 docker 容器"
        case .containerLogs: return "讀取指定容器的日誌"
        case .readFile: return "讀取伺服器上的檔案內容"
        case .search: return "篩選含有（或不含）指定文字的行"
        case .replace: return "把文字取代成另一段文字"
        case .head: return "只保留前幾行"
        case .tail: return "只保留後幾行"
        case .countLines: return "計算輸出的行數"
        case .sort: return "依字母或數字排序"
        case .unique: return "去除重複的行"
        }
    }
}

enum ContainerColumn: String, CaseIterable, Identifiable, Sendable {
    case name, image, status, ports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名稱"
        case .image: return "映像"
        case .status: return "狀態"
        case .ports: return "Port"
        }
    }

    var template: String {
        switch self {
        case .name: return "{{.Names}}"
        case .image: return "{{.Image}}"
        case .status: return "{{.Status}}"
        case .ports: return "{{.Ports}}"
        }
    }
}

struct Block: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: BlockKind
    var includeStopped = true
    var columns: [ContainerColumn] = [.name, .status]
    var container = ""
    var path = ""
    var text = ""
    var replacement = ""
    var ignoreCase = true
    var invert = false
    var useRegex = false
    var count = 10
    var reverse = false
    var numeric = false

    init(kind: BlockKind) {
        self.id = UUID()
        self.kind = kind
        if kind == .containerLogs {
            self.count = 100
        }
    }

    var command: String? {
        switch kind {
        case .containerList:
            guard !columns.isEmpty else { return nil }
            let ordered = ContainerColumn.allCases.filter { columns.contains($0) }
            let format = ordered.map(\.template).joined(separator: "\\t")
            var cmd = "docker ps"
            if includeStopped { cmd += " -a" }
            cmd += " --format " + ShellQuote.quote(format)
            return cmd
        case .containerLogs:
            let c = container.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, count >= 1 else { return nil }
            return "docker logs --tail \(count) " + ShellQuote.quote(c) + " 2>&1"
        case .readFile:
            let p = path.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            if p.hasPrefix("~/") {
                let rest = String(p.dropFirst(2))
                return "cat ~/" + ShellQuote.quote(rest)
            }
            return "cat " + ShellQuote.quote(p)
        case .search:
            guard !text.isEmpty else { return nil }
            var cmd = "grep"
            if ignoreCase { cmd += " -i" }
            if invert { cmd += " -v" }
            cmd += useRegex ? " -E" : " -F"
            cmd += " -- " + ShellQuote.quote(text)
            return cmd
        case .replace:
            guard !text.isEmpty else { return nil }
            let pattern = "s/" + escapeFind(text) + "/" + escapeReplacement(replacement) + "/g"
            return "sed " + ShellQuote.quote(pattern)
        case .head:
            guard count >= 1 else { return nil }
            return "head -n \(count)"
        case .tail:
            guard count >= 1 else { return nil }
            return "tail -n \(count)"
        case .countLines:
            return "wc -l"
        case .sort:
            var cmd = "sort"
            if reverse { cmd += " -r" }
            if numeric { cmd += " -n" }
            return cmd
        case .unique:
            return "sort -u"
        }
    }
}

func escapeFind(_ s: String) -> String {
    var result = ""
    for ch in s {
        if "\\/.*[]^$".contains(ch) {
            result.append("\\")
        }
        result.append(ch)
    }
    return result
}

func escapeReplacement(_ s: String) -> String {
    var result = ""
    for ch in s {
        if ch == "\\" || ch == "/" || ch == "&" {
            result.append("\\")
        }
        result.append(ch)
    }
    return result
}

func pipelineCommand(_ blocks: [Block]) -> String? {
    guard let first = blocks.first, first.kind.isSource else { return nil }
    guard blocks.dropFirst().allSatisfy({ !$0.kind.isSource }) else { return nil }
    var commands: [String] = []
    for block in blocks {
        guard let cmd = block.command else { return nil }
        commands.append(cmd)
    }
    return commands.joined(separator: " | ")
}
```

```swift
// File: WorkspaceModel.swift
import Foundation
import VisualTerminalCore

struct LogEntry: Identifiable {
    let id: UUID
    let command: String
    let startedAt: Date
    var output: String = ""
    var exitCode: Int32?
    var stopped = false
    var running = true

    init(command: String) {
        self.id = UUID()
        self.command = command
        self.startedAt = Date()
    }
}

@MainActor
@Observable
final class WorkspaceModel {
    private let connection: SSHConnection
    var blocks: [Block] = [Block(kind: .containerList)]
    var containers: [String] = []
    var log: [LogEntry] = []
    var isRunning = false

    private var runTask: Task<Void, Never>?

    init(connection: SSHConnection) {
        self.connection = connection
    }

    var command: String? {
        pipelineCommand(blocks)
    }

    func add(_ kind: BlockKind) {
        let block = Block(kind: kind)
        if kind.isSource {
            if blocks.first?.kind.isSource == true {
                blocks[0] = block
            } else {
                blocks.insert(block, at: 0)
            }
        } else {
            blocks.append(block)
        }
    }

    func remove(_ id: UUID) {
        blocks.removeAll { $0.id == id }
    }

    func move(_ id: UUID, up: Bool) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 1, target < blocks.count else { return }
        blocks.swapAt(index, target)
    }

    func loadContainers() async {
        do {
            let (out, _, _) = try await connection.runCollecting("docker ps -a --format '{{.Names}}'")
            containers = out.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        } catch {
            containers = []
        }
    }

    func run() {
        guard let cmd = command, !isRunning else { return }
        let entry = LogEntry(command: cmd)
        log.append(entry)
        let entryID = entry.id
        isRunning = true

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.connection.run(cmd) {
                    if Task.isCancelled { break }
                    switch event {
                    case .stdout(let text), .stderr(let text):
                        self.appendOutput(text, to: entryID)
                    case .exit(let code):
                        self.setExitCode(code, for: entryID)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.appendOutput("\n執行失敗：" + error.localizedDescription, to: entryID)
                }
            }
            self.finish(entryID)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        if let idx = log.lastIndex(where: { $0.running }) {
            log[idx].stopped = true
            log[idx].running = false
        }
        isRunning = false
    }

    func clearLog() {
        log.removeAll()
    }

    private func appendOutput(_ text: String, to id: UUID) {
        guard let idx = log.firstIndex(where: { $0.id == id }) else { return }
        let current = log[idx].output
        if current.count >= 200_000 {
            if !current.hasSuffix("…（輸出過長，已截斷）") {
                log[idx].output = current + "…（輸出過長，已截斷）"
            }
            return
        }
        log[idx].output += text
        if log[idx].output.count > 200_000 {
            log[idx].output = String(log[idx].output.prefix(200_000)) + "…（輸出過長，已截斷）"
        }
    }

    private func setExitCode(_ code: Int32, for id: UUID) {
        guard let idx = log.firstIndex(where: { $0.id == id }) else { return }
        log[idx].exitCode = code
    }

    private func finish(_ id: UUID) {
        guard let idx = log.firstIndex(where: { $0.id == id }) else { return }
        log[idx].running = false
        isRunning = false
        runTask = nil
    }
}
```

Wait — stop(): cancel task; the task's for-await will throw/break, then finish() sets running=false. But stop also sets stopped=true. finish sets running=false but doesn't touch stopped. Good. But finish sets isRunning=false — fine.

One issue: stop() sets stopped on last running entry; finish also runs. OK.

```swift
// File: WorkspaceView.swift
import SwiftUI
import VisualTerminalCore

struct WorkspaceView: View {
    @Environment(SessionModel.self) private var session
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                HSplitView {
                    BlockPaletteView(model: model)
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                    VSplitView {
                        PipelineEditorView(model: model)
                        OutputLogView(model: model)
                    }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil, let conn = session.connection {
                let m = WorkspaceModel(connection: conn)
                model = m
                Task { await m.loadContainers() }
            }
        }
    }
}
```

Hmm, onAppear with @State model — fine. But session.connection could be nil; guard.

```swift
// File: BlockPaletteView.swift
import SwiftUI

struct BlockPaletteView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            paletteSection(title: "資料來源", kinds: BlockKind.allCases.filter(\.isSource))
            paletteSection(title: "過濾與處理", kinds: BlockKind.allCases.filter { !$0.isSource })
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func paletteSection(title: String, kinds: [BlockKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(kinds) { kind in
                Button {
                    model.add(kind)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: kind.symbol)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.callout.weight(.medium))
                            Text(kind.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

PipelineEditorView:

```swift
// File: PipelineEditorView.swift
import SwiftUI

struct PipelineEditorView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockCard(block: block, index: index, model: model)
                        if index < model.blocks.count - 1 {
                            Image(systemName: "arrow.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(model.command ?? "請完成拼塊設定")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(model.command == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.isRunning {
                    Button("停止") { model.stop() }
                        .keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button("執行") { model.run() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.command == nil)
                }
            }
        }
        .padding()
    }
}
```

BlockCard with parameter controls. Need Binding for block fields — blocks is array of structs; use Binding(get:set:) with index.

```swift
struct BlockCard: View {
    let block: Block
    let index: Int
    let model: WorkspaceModel

    private func binding<T>(_ keyPath: WritableKeyPath<Block, T>) -> Binding<T> {
        Binding(
            get: { model.blocks.first(where: { $0.id == block.id })?[keyPath: keyPath] ?? block[keyPath: keyPath] },
            set: { newValue in
                if let i = model.blocks.firstIndex(where: { $0.id == block.id }) {
                    model.blocks[i][keyPath: keyPath] = newValue
                }
            }
        )
    }
```

Hmm, WritableKeyPath with Block — fine. But `block[keyPath: keyPath]` on let block — get works.

For columns toggle: binding for columns array — custom.

Card body:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Image(systemName: block.kind.symbol)
            Text(block.kind.title).font(.headline)
            Spacer()
            if !block.kind.isSource {
                Button { model.move(block.id, up: true) } label: { Image(systemName: "chevron.up") }
                    .disabled(index <= 1)
                Button { model.move(block.id, up: false) } label: { Image(systemName: "chevron.down") }
                    .disabled(index >= model.blocks.count - 1)
            }
            Button(role: .destructive) { model.remove(block.id) } label: { Image(systemName: "trash") }
        }
        controls
    }
    .padding(10)
    .background(...)
}
```

Controls per kind. For containerList: Toggle includeStopped; columns toggles.

For containerLogs: Picker of containers + refresh button; Stepper/TextField count.

Count control: Stepper("行數：\(count)", value: binding, in: 1...10000) plus TextField? Spec says Stepper/TextField. Use Stepper.

OutputLogView:

```swift
struct OutputLogView: View {
    let model: WorkspaceModel
    @State private var scrollID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("輸出紀錄").font(.headline)
                Spacer()
                Button("清除紀錄") { model.clearLog() }
                    .disabled(model.log.isEmpty)
            }
            .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.log) { entry in
                            LogEntryView(entry: entry)
                                .id(entry.id)
                        }
                        if model.log.isEmpty {
                            Text("尚無輸出紀錄").foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.log.last?.output) { _, _ in
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .textBackgroundColor))
    }
}
```

onChange signature in macOS 15: `.onChange(of:) { old, new in }` or `{ new in }`. Use `{ _, _ in }`? In Swift 6 / macOS 15, onChange(of:initial:_:) with two params. Use `.onChange(of: model.log.last?.output) { _, _ in ... }` — should compile.

LogEntryView:

```swift
struct LogEntryView: View {
    let entry: LogEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ " + entry.command).font(.system(.callout, design: .monospaced)).foregroundStyle(.green)
            if !entry.output.isEmpty {
                Text(entry.output).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                if entry.running {
                    ProgressView().controlSize(.small)
                    Text("執行中…")
                } else if entry.stopped {
                    Text("已停止")
                } else if let code = entry.exitCode {
                    Text("結束碼 " + String(code))
                } else {
                    Text("已結束")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
```

Dark terminal look: background dark, text light. Use Color(nsColor: .textBackgroundColor)? That's light. Better use a dark background: Color(red:0.12,...) with white text. Spec says 深色區塊. Use `Color(nsColor: .windowBackgroundColor)`? Just use dark: `Color(red: 0.15, green: 0.15, blue: 0.17)` and foregroundStyle(.white).

PipelineEditorView needs BlockCard — put BlockCard in PipelineEditorView.swift.

Columns toggle binding:

```swift
Toggle("名稱", isOn: Binding(
    get: { block.columns.contains(.name) },
    set: { on in
        var cols = block.columns
        if on { if !cols.contains(.name) { cols.append(.name) } }
        else { cols.removeAll { $0 == .name } }
        setColumns(cols)
    }
))
```

setColumns via model.blocks index.

Container picker: Picker("", selection: binding(\.container)) { Text("選擇容器").tag("") ; ForEach(model.containers, id: \.self) { Text($0).tag($0) } }. Refresh button calls Task { await model.loadContainers() }.

Count: Stepper(value: binding(\.count), in: 1...10000) { Text("行數：\(block.count)") }.

Now write it all.```swift
// File: WorkspaceModel.swift
import Foundation
import VisualTerminalCore

struct LogEntry: Identifiable {
    let id: UUID
    let command: String
    let startedAt: Date
    var output: String = ""
    var exitCode: Int32?
    var stopped = false
    var running = true

    init(command: String) {
        self.id = UUID()
        self.command = command
        self.startedAt = Date()
    }
}

@MainActor
@Observable
final class WorkspaceModel {
    private let connection: SSHConnection
    var blocks: [Block] = [Block(kind: .containerList)]
    var containers: [String] = []
    var log: [LogEntry] = []
    var isRunning = false

    private var runTask: Task<Void, Never>?

    init(connection: SSHConnection) {
        self.connection = connection
    }

    var command: String? {
        pipelineCommand(blocks)
    }

    func add(_ kind: BlockKind) {
        let block = Block(kind: kind)
        if kind.isSource {
            if blocks.first?.kind.isSource == true {
                blocks[0] = block
            } else {
                blocks.insert(block, at: 0)
            }
        } else {
            blocks.append(block)
        }
    }

    func remove(_ id: UUID) {
        blocks.removeAll { $0.id == id }
    }

    func move(_ id: UUID, up: Bool) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 1, target < blocks.count else { return }
        blocks.swapAt(index, target)
    }

    func loadContainers() async {
        do {
            let (out, _, _) = try await connection.runCollecting("docker ps -a --format '{{.Names}}'")
            containers = out.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        } catch {
            containers = []
        }
    }

    func run() {
        guard let cmd = command, !isRunning else { return }
        let entry = LogEntry(command: cmd)
        log.append(entry)
        let entryID = entry.id
        isRunning = true

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.connection.run(cmd) {
                    if Task.isCancelled { break }
                    switch event {
                    case .stdout(let text), .stderr(let text):
                        self.appendOutput(text, to: entryID)
                    case .exit(let code):
                        self.setExitCode(code, for: entryID)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.appendOutput("\n執行失敗：" + error.localizedDescription, to: entryID)
                }
            }
            self.finish(entryID)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        if let idx = log.lastIndex(where: { $0.running }) {
            log[idx].stopped = true
            log[idx].running = false
        }
        isRunning = false
    }

    func clearLog() {
        log.removeAll()
    }

    private func appendOutput(_ text: String, to id: UUID) {
        guard let idx = log.firstIndex(where: { $0.id == id }) else { return }
        let current = log[idx].output
        if current.count >= 200_000 {
            if !current.hasSuffix("…（輸出過長，已截斷）") {
                log[idx].output = current + "…（輸出過長，已截斷）"
            }
            return
        }
        log[idx].output += text
        if log[idx].output.count > 200_000 {
            log[idx].output = String(log[idx].output.prefix(200_000)) + "…（輸出過長，已截斷）"
        }
    }

    private func setExitCode(_ code: Int32, for id: UUID) {
        guard let idx = log.firstIndex(where: { $0.id == id }) else { return }
        log[idx].exitCode = code
    }

    private func finish(_ id: UUID) {
        guard let idx = log.firstIndex(where: { $0.id == id }) else { return }
        log[idx].running = false
        isRunning = false
        runTask = nil
    }
}
```

```swift
// File: WorkspaceView.swift
import SwiftUI
import VisualTerminalCore

struct WorkspaceView: View {
    @Environment(SessionModel.self) private var session
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                HSplitView {
                    BlockPaletteView(model: model)
                        .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                    VSplitView {
                        PipelineEditorView(model: model)
                        OutputLogView(model: model)
                    }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil, let conn = session.connection {
                let m = WorkspaceModel(connection: conn)
                model = m
                Task { await m.loadContainers() }
            }
        }
    }
}
```

```swift
// File: BlockPaletteView.swift
import SwiftUI

struct BlockPaletteView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            paletteSection(title: "資料來源", kinds: BlockKind.allCases.filter(\.isSource))
            paletteSection(title: "過濾與處理", kinds: BlockKind.allCases.filter { !$0.isSource })
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func paletteSection(title: String, kinds: [BlockKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ForEach(kinds) { kind in
                Button {
                    model.add(kind)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: kind.symbol)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.callout.weight(.medium))
                            Text(kind.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

```swift
// File: PipelineEditorView.swift
import SwiftUI

struct PipelineEditorView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockCard(block: block, index: index, model: model)
                        if index < model.blocks.count - 1 {
                            Image(systemName: "arrow.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                Text(model.command ?? "請完成拼塊設定")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(model.command == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.isRunning {
                    Button("停止") { model.stop() }
                        .keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button("執行") { model.run() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.command == nil)
                }
            }
        }
        .padding()
    }
}

private struct BlockCard: View {
    let block: Block
    let index: Int
    let model: WorkspaceModel

    private func setField<T>(_ keyPath: WritableKeyPath<Block, T>, _ value: T) {
        guard let i = model.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        model.blocks[i][keyPath: keyPath] = value
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Block, T>) -> Binding<T> {
        Binding(
            get: { model.blocks.first(where: { $0.id == block.id })?[keyPath: keyPath] ?? block[keyPath: keyPath] },
            set: { setField(keyPath, $0) }
        )
    }

    private func setColumns(_ cols: [ContainerColumn]) {
        guard let i = model.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        model.blocks[i].columns = cols
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: block.kind.symbol)
                Text(block.kind.title)
                    .font(.headline)
                Spacer()
                if !block.kind.isSource {
                    Button { model.move(block.id, up: true) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index <= 1)
                    .help("上移")
                    Button { model.move(block.id, up: false) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index >= model.blocks.count - 1)
                    .help("下移")
                }
                Button(role: .destructive) { model.remove(block.id) } label: {
                    Image(systemName: "trash")
                }
                .help("刪除")
            }

            controls
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var controls: some View {
        switch block.kind {
        case .containerList:
            Toggle("包含已停止的容器", isOn: binding(\.includeStopped))
            HStack(spacing: 12) {
                ForEach(ContainerColumn.allCases) { col in
                    Toggle(col.title, isOn: Binding(
                        get: { block.columns.contains(col) },
                        set: { on in
                            var cols = block.columns
                            if on {
                                if !cols.contains(col) { cols.append(col) }
                            } else {
                                cols.removeAll { $0 == col }
                            }
                            setColumns(cols)
                        }
                    ))
                }
            }
        case .containerLogs:
            HStack {
                Picker("容器", selection: binding(\.container)) {
                    Text("選擇容器").tag("")
                    ForEach(model.containers, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(maxWidth: 260)
                Button {
                    Task { await model.loadContainers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新整理容器清單")
            }
            Stepper("行數：\(block.count)", value: binding(\.count), in: 1...10000)
        case .readFile:
            TextField("檔案路徑（例如 ~/logs/app.log）", text: binding(\.path))
                .textFieldStyle(.roundedBorder)
        case .search:
            TextField("要找的文字", text: binding(\.text))
                .textFieldStyle(.roundedBorder)
            Toggle("不分大小寫", isOn: binding(\.ignoreCase))
            Toggle("排除含有的行", isOn: binding(\.invert))
            Toggle("使用正規表示式", isOn: binding(\.useRegex))
        case .replace:
            TextField("找", text: binding(\.text))
                .textFieldStyle(.roundedBorder)
            TextField("取代成", text: binding(\.replacement))
                .textFieldStyle(.roundedBorder)
        case .head, .tail:
            Stepper("行數：\(block.count)", value: binding(\.count), in: 1...10000)
        case .sort:
            Toggle("由大到小", isOn: binding(\.reverse))
            Toggle("依數字大小", isOn: binding(\.numeric))
        case .countLines, .unique:
            Text(block.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

```swift
// File: OutputLogView.swift
import SwiftUI

struct OutputLogView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("輸出紀錄")
                    .font(.headline)
                Spacer()
                Button("清除紀錄") { model.clearLog() }
                    .disabled(model.log.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.log.isEmpty {
                            Text("尚無輸出紀錄")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(model.log) { entry in
                            LogEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.log.last?.output) { _, _ in
                    if let last = model.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding()
        .background(Color(red: 0.13, green: 0.13, blue: 0.15))
        .foregroundStyle(.white)
    }
}

private struct LogEntryView: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ " + entry.command)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.green)
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if entry.running {
                    ProgressView()
                        .controlSize(.small)
                    Text("執行中…")
                } else if entry.stopped {
                    Text("已停止")
                } else if let code = entry.exitCode {
                    Text("結束碼 " + String(code))
                } else {
                    Text("已結束")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
```

注意：`Block` 的 `command` 用 `ShellQuote.quote`，`escapeFind` 的字串 `"\\/.*[]^$"` 中 `[` 和 `]` 在字面字串中沒有特殊意義，`contains(ch)` 逐字元比對即可。`\t` 在 format 中是反斜線加 t（`"\\t"`），正確。