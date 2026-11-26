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
