import SwiftUI

/// 划词窗口的内容区尺寸，使用逻辑点。宽高成对更新，避免读到混合尺寸。
enum WordStudyWindowSettings {
    static let preferenceKey = "wordStudy.windowSize"
    static let defaultSize = CGSize(width: 480, height: 620)
    static let minimumSize = CGSize(width: 360, height: 300)
    static let maximumSize = CGSize(width: 2400, height: 2000)
    static let defaultPreferenceValue = preferenceValue(for: defaultSize)

    static func size(from value: String) -> CGSize {
        let dimensions = value.split(separator: ",", omittingEmptySubsequences: false)
        guard dimensions.count == 2,
              let width = Double(dimensions[0]), let height = Double(dimensions[1]) else {
            return defaultSize
        }
        return normalized(CGSize(width: width, height: height))
    }

    static func preferenceValue(for size: CGSize) -> String {
        let size = normalized(size)
        return "\(Int(size.width)),\(Int(size.height))"
    }

    private static func normalized(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite else { return defaultSize }
        return CGSize(
            width: min(max(size.width.rounded(), minimumSize.width), maximumSize.width),
            height: min(max(size.height.rounded(), minimumSize.height), maximumSize.height)
        )
    }
}

struct WordStudyWindowSettingsControls: View {
    private enum Dimension: Hashable {
        case width, height
    }

    @AppStorage(WordStudyWindowSettings.preferenceKey)
    private var storedSize = WordStudyWindowSettings.defaultPreferenceValue
    @FocusState private var focusedDimension: Dimension?
    @State private var widthDraft = ""
    @State private var heightDraft = ""
    @State private var editedDimension: Dimension?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dimensionField("窗口宽度", dimension: .width, text: $widthDraft)
            dimensionField("窗口高度", dimension: .height, text: $heightDraft)
            HStack(alignment: .firstTextBaseline) {
                Text("拖动划词窗口边缘也会保存尺寸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button("恢复默认", action: restoreDefault)
            }
        }
        .onChange(of: storedSize, initial: true) { _, value in syncDrafts(from: value) }
        .onChange(of: focusedDimension) { previous, _ in
            if let previous { commit(previous) }
        }
    }

    private func dimensionField(_ title: String, dimension: Dimension, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: Binding(get: { text.wrappedValue }, set: { value in
                    text.wrappedValue = value
                    editedDimension = dimension
                }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 76)
                .focused($focusedDimension, equals: dimension)
                .onSubmit { commit(dimension) }
                Text("点")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commit(_ dimension: Dimension) {
        guard editedDimension == dimension else { return }
        let draft = dimension == .width ? widthDraft : heightDraft
        guard let value = Double(draft.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            syncDrafts(from: storedSize)
            return
        }
        var size = WordStudyWindowSettings.size(from: storedSize)
        switch dimension {
        case .width: size.width = value
        case .height: size.height = value
        }
        let preference = WordStudyWindowSettings.preferenceValue(for: size)
        if preference != storedSize { storedSize = preference }
        syncDrafts(from: preference)
    }

    private func restoreDefault() {
        storedSize = WordStudyWindowSettings.defaultPreferenceValue
        syncDrafts(from: storedSize)
        focusedDimension = nil
    }

    private func syncDrafts(from value: String) {
        let size = WordStudyWindowSettings.size(from: value)
        widthDraft = String(Int(size.width))
        heightDraft = String(Int(size.height))
        editedDimension = nil
    }
}
