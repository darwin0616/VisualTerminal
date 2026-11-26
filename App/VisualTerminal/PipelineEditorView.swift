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
