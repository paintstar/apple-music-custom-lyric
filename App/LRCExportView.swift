import SwiftUI
import UniformTypeIdentifiers
import ShinAppleKit
import ShinAppServices

// LRC 导出对话框与文件写出封装（全中文）：
// - 模式选择：原始时间（不写 offset 标签）/ 应用当前偏移（一次性写入）；
// - 信息损失说明固定可见（译文/元信息/行 id/待复核/offset 处理方式）；
// - 负时间裁剪提示（如有）；确认后经系统面板写出 UTF-8 文件。

// MARK: - 文件写出封装（SwiftUI FileDocument）

/// LRC 文本写出（UTF-8）。
struct LRCFileDocument: FileDocument {
    static let lrcType = UTType(filenameExtension: "lrc") ?? .plainText
    static var writableContentTypes: [UTType] { [lrcType] }
    static var readableContentTypes: [UTType] { [lrcType] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(
            data: configuration.file.regularFileContents ?? Data(),
            encoding: .utf8
        ) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 备份 JSON 写出（UTF-8）。
struct BackupJSONDocument: FileDocument {
    static var writableContentTypes: [UTType] { [.json] }
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - LRC 导出对话框

struct LRCExportSheet: View {
    @ObservedObject var library: LyricsLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var isExportingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出 LRC")
                .font(.title3.weight(.semibold))
            if let state = library.lrcExport {
                Text("文档：\(LyricsLibraryModel.displayName(for: state.item))")
                    .font(.callout)
                Picker("导出模式", selection: modeBinding) {
                    Text("原始时间（不写 offset 标签）").tag(LRCExportMode.originalTimes)
                    Text("应用当前偏移（一次性写入）").tag(LRCExportMode.appliedOffset)
                }
                .pickerStyle(.radioGroup)
                lossNotesSection(state)
                clampWarning(state)
                Text("完整保留译文、关联与待复核标记请使用「导出完整备份（JSON）」；LRC 仅用于与其他播放器互操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消", role: .cancel) {
                    library.cancelLRCExport()
                    dismiss()
                }
                Spacer()
                Button("导出文件…") {
                    isExportingFile = true
                }
                .disabled(library.lrcExport?.result == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .fileExporter(
            isPresented: $isExportingFile,
            document: library.lrcExport?.result.map { LRCFileDocument(text: $0.text) },
            contentType: LRCFileDocument.lrcType,
            defaultFilename: LyricsLibraryView.lrcFilename(for: library.lrcExport?.item)
        ) { _ in
            library.cancelLRCExport()
            dismiss()
        }
    }

    private var modeBinding: Binding<LRCExportMode> {
        Binding(
            get: { library.lrcExport?.mode ?? .originalTimes },
            set: { newValue in
                Task { await library.changeLRCMode(newValue) }
            }
        )
    }

    @ViewBuilder
    private func lossNotesSection(_ state: LyricsLibraryModel.LRCExportState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("信息损失说明（导出前请阅读）", systemImage: "doc.text.magnifyingglass")
                .font(.callout.weight(.semibold))
            if let result = state.result {
                ForEach(Array(result.lossNotes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "minus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("正在计算导出内容……")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func clampWarning(_ state: LyricsLibraryModel.LRCExportState) -> some View {
        if let count = state.result?.clampedLineCount, count > 0 {
            Label(
                "有 \(count) 行应用偏移后时间为负，将被裁剪为 0（导出文件中的这些行会提前到开头）。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(.callout)
        }
    }
}
