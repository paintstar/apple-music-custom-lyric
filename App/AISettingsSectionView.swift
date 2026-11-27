import SwiftUI
import ShinAIProvider
import ShinAppleKit

/// AI 学习服务配置分区视图模型。
/// 非敏感配置存于 `UserDefaults`（`AIServiceSettingsStore`），API Key 仅读写 macOS 钥匙串。
@MainActor
final class AISettingsSectionModel: ObservableObject {
    @Published var preset: AIProviderPreset
    @Published var baseURLString: String
    @Published var modelName: String
    @Published var preferredPronunciationStyle: PronunciationStyle
    @Published var apiKeyInput = ""
    @Published private(set) var hasSavedAPIKey = false
    @Published private(set) var keyStatusMessage: String?
    @Published private(set) var keyStatusIsError = false
    @Published private(set) var isTestingConnection = false
    @Published private(set) var connectionStatusMessage: String?
    @Published private(set) var connectionStatusIsSuccess = false

    private let settingsStore: AIServiceSettingsStore
    private let credentialStore: any AICredentialStoring
    private let client: any AIStudyProviding
    private var testTask: Task<Void, Never>?
    private var testSequence = 0

    init(
        settingsStore: AIServiceSettingsStore = AIServiceSettingsStore(),
        credentialStore: any AICredentialStoring = SystemKeychainCredentialStore(),
        client: (any AIStudyProviding)? = nil
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.client = client ?? OpenAICompatibleClient(credentialStore: credentialStore)

        let stored = settingsStore.load()
        self.preset = stored.preset
        self.baseURLString = stored.baseURLString
        self.modelName = stored.modelName
        self.preferredPronunciationStyle = stored.preferredPronunciationStyle
        refreshKeychainPresence()
    }

    var currentConfiguration: AIConfiguration {
        AIConfiguration(
            preset: preset,
            baseURLString: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredTargetLanguage: "zh-Hans",
            preferredPronunciationStyle: preferredPronunciationStyle
        )
    }

    var endpointValidationWarning: String? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try validatedEndpointURL(baseURLString: trimmed)
            return nil
        } catch let error as AIProviderError {
            return error.userMessage
        } catch {
            return error.localizedDescription
        }
    }

    func selectPreset(_ newPreset: AIProviderPreset) {
        guard newPreset != preset else { return }
        preset = newPreset
        if newPreset != .custom {
            baseURLString = newPreset.defaultBaseURL
            modelName = newPreset.defaultModel
        }
        apiKeyInput = ""
        keyStatusMessage = nil
        keyStatusIsError = false
        connectionStatusMessage = nil
        cancelOngoingTest()
        persistConfiguration()
        refreshKeychainPresence()
    }

    func persistConfiguration() {
        settingsStore.save(currentConfiguration)
    }

    func refreshKeychainPresence() {
        do {
            hasSavedAPIKey = try credentialStore.hasAPIKey(for: preset)
        } catch {
            hasSavedAPIKey = false
            keyStatusIsError = true
            keyStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentialStore.saveAPIKey(trimmed, for: preset)
            apiKeyInput = ""
            hasSavedAPIKey = true
            keyStatusIsError = false
            keyStatusMessage = "已保存至系统钥匙串。"
        } catch {
            keyStatusIsError = true
            keyStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearAPIKey() {
        do {
            try credentialStore.deleteAPIKey(for: preset)
            apiKeyInput = ""
            hasSavedAPIKey = false
            keyStatusIsError = false
            keyStatusMessage = "已从系统钥匙串清除该预设密钥。"
        } catch {
            keyStatusIsError = true
            keyStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func testConnection() {
        cancelOngoingTest()
        testSequence += 1
        let expectedSequence = testSequence
        isTestingConnection = true
        connectionStatusMessage = nil
        connectionStatusIsSuccess = false

        let config = currentConfiguration
        let enteredKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitKey = enteredKey.isEmpty ? nil : enteredKey
        let serviceClient = client

        testTask = Task { [weak self] in
            do {
                let result = try await serviceClient.testConnection(
                    configuration: config,
                    apiKey: explicitKey
                )
                guard let self, !Task.isCancelled, self.testSequence == expectedSequence else { return }
                self.isTestingConnection = false
                self.connectionStatusIsSuccess = true
                self.connectionStatusMessage = "连接成功（\(result.latencyMs) ms · 模型：\(result.model)）"
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.testSequence == expectedSequence else { return }
                self.isTestingConnection = false
                self.connectionStatusIsSuccess = false
                self.connectionStatusMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    func cancelOngoingTest() {
        testSequence += 1
        testTask?.cancel()
        testTask = nil
        isTestingConnection = false
    }
}

/// 设置页「AI 学习服务」分区内容：服务商配置、系统钥匙串密钥管理、连接测试与注音偏好。
struct AISettingsSectionView: View {
    static let pronunciationsSettingKey = "lyrics.showPronunciations"
    private static let selectablePronunciationStyles: [PronunciationStyle] = [
        .romaji,
        .furigana,
        .ipa,
        .hangulRomanization
    ]

    @StateObject private var model = AISettingsSectionModel()
    @AppStorage(AISettingsSectionView.pronunciationsSettingKey)
    private var showPronunciations = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerRows
            apiKeyRow
            connectionTestRow
            Divider()
            studyPreferencesRows
        }
        .onDisappear { model.cancelOngoingTest() }
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledRow("服务商预设") {
                Picker("服务商预设", selection: presetBinding) {
                    ForEach(AIProviderPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
            }

            labeledRow("Base URL") {
                TextField(
                    model.preset == .custom ? "https://example.com/v1" : model.preset.defaultBaseURL,
                    text: $model.baseURLString
                )
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onChange(of: model.baseURLString) { _, _ in
                    model.persistConfiguration()
                }
            }

            if let warning = model.endpointValidationWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 96)
            }

            labeledRow("模型名称") {
                TextField(
                    model.preset == .custom ? "输入模型 ID" : model.preset.defaultModel,
                    text: $model.modelName
                )
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onChange(of: model.modelName) { _, _ in
                    model.persistConfiguration()
                }
            }
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledRow("API Key") {
                HStack(spacing: 8) {
                    SecureField(apiKeyPlaceholder, text: $model.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveAPIKey() }
                    Button("保存密钥") { model.saveAPIKey() }
                        .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("清除") { model.clearAPIKey() }
                        .disabled(!model.hasSavedAPIKey)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(keyStateText)
                        .font(.caption)
                        .foregroundStyle(model.hasSavedAPIKey ? .green : .secondary)
                    if let status = model.keyStatusMessage {
                        Text("· \(status)")
                            .font(.caption)
                            .foregroundStyle(model.keyStatusIsError ? .red : .secondary)
                    }
                }
                Text("密钥只存于 macOS 钥匙串，不进入本地库与备份")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 96)
        }
    }

    private var connectionTestRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    model.testConnection()
                } label: {
                    if model.isTestingConnection {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在测试……")
                        }
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(model.isTestingConnection)

                if let status = model.connectionStatusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(model.connectionStatusIsSuccess ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var studyPreferencesRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledRow("默认注音形式") {
                Picker("默认注音形式", selection: pronunciationBinding) {
                    ForEach(Self.selectablePronunciationStyles, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200, alignment: .leading)
            }

            Toggle("在歌词中显示注音", isOn: $showPronunciations)
                .help("开启后，在歌词原文上方或附近展示已生成的逐行注音")

            Text("AI 解析、翻译与注音均由你主动触发并预览确认后才写入本地歌词；文本注音不代表歌手实际演唱唱法。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetBinding: Binding<AIProviderPreset> {
        Binding(
            get: { model.preset },
            set: { model.selectPreset($0) }
        )
    }

    private var pronunciationBinding: Binding<PronunciationStyle> {
        Binding(
            get: {
                Self.selectablePronunciationStyles.contains(model.preferredPronunciationStyle)
                    ? model.preferredPronunciationStyle
                    : .romaji
            },
            set: { newValue in
                model.preferredPronunciationStyle = newValue
                model.persistConfiguration()
            }
        )
    }

    private var apiKeyPlaceholder: String {
        if model.hasSavedAPIKey {
            return "已保存于系统钥匙串（输入新密钥可覆盖）"
        }
        return model.preset.requiresAPIKey ? "输入 API Key" : "本地 Ollama 通常无需密钥（可选）"
    }

    private var keyStateText: String {
        if model.hasSavedAPIKey {
            return "已保存于系统钥匙串"
        }
        return model.preset.requiresAPIKey ? "当前预设尚未保存密钥" : "本地服务免密钥"
    }

    private func labeledRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content()
        }
    }
}
