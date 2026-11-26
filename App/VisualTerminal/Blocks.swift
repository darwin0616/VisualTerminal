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
