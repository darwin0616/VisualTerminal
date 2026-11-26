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
