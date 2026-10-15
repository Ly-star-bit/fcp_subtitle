import FCPSubtitleCore
import SwiftUI

/// Sends the current subtitles to an OpenAI-compatible endpoint to catch ASR
/// typos, then lets the user pick which suggestions to apply. Nothing is
/// changed until 应用 is pressed.
struct ProofreadSheet: View {
    let undoManager: UndoManager?
    @ObservedObject private var state = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var resultNote: String?

    init(undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings || state.llmAPIKey.isEmpty {
                settings
                Divider()
            }
            body_
            Divider()
            footer
        }
        .frame(width: 660, height: 540)
        .onAppear {
            if state.llmAPIKey.isEmpty { showSettings = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("AI 校对错别字", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button {
                showSettings.toggle()
            } label: {
                Label("接口设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Settings

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("接口地址")
                TextField("https://api.openai.com/v1", text: $state.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("API Key")
                SecureField("sk-…", text: $state.llmAPIKey)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("模型")
                TextField("gpt-4o-mini", text: $state.llmModel)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("每批句数")
                HStack {
                    Stepper("\(state.llmBatchSize) 句", value: $state.llmBatchSize, in: 10...100, step: 10)
                        .fixedSize()
                    Toggle("走代理", isOn: $state.llmUseProxy)
                        .help("使用「模型管理」页里配置的代理地址")
                    Spacer()
                }
            }
            GridRow {
                Text("")
                HStack(spacing: 8) {
                    Button {
                        state.testLLMConnection()
                    } label: {
                        if state.llmTesting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("测试中…")
                            }
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(state.llmTesting || state.llmAPIKey.isEmpty)

                    switch state.llmTestResult {
                    case .ok(let model):
                        Label("连接正常 · \(model)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    case .failed(let message):
                        Label(message, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    case nil:
                        Text("兼容 OpenAI 格式的服务都可以填,如 DeepSeek、通义、Ollama、one-api。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding()
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        switch state.proofread {
        case .idle:
            centered {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("把当前 \(state.selectedFile?.segments.count ?? 0) 句字幕交给大模型检查同音错别字")
                    .foregroundStyle(.secondary)
                Text("只找错字和标点,不会改写句子,也不会动时间轴")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .running(let done, let total):
            centered {
                ProgressView(
                    value: total > 0 ? Double(done) / Double(total) : nil,
                    total: 1
                )
                .frame(maxWidth: 260)
                Text(total > 0 ? "校对中… \(done)/\(total) 批" : "校对中…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("取消") { state.cancelProofread() }
            }
        case .failed(let message):
            centered {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
                Button("检查接口设置") { showSettings = true }
            }
        case .finished(let count):
            if count == 0 {
                centered {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("没有发现明显的错别字")
                        .foregroundStyle(.secondary)
                }
            } else {
                correctionList
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var correctionList: some View {
        List {
            ForEach(state.corrections) { correction in
                HStack(alignment: .top, spacing: 10) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { state.acceptedCorrections.contains(correction.id) },
                            set: { on in
                                if on {
                                    state.acceptedCorrections.insert(correction.id)
                                } else {
                                    state.acceptedCorrections.remove(correction.id)
                                }
                            })
                    )
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(timeLabel(correction.start))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(correction.original)
                            .foregroundStyle(.secondary)
                            .strikethrough(color: .red.opacity(0.6))
                        Text(correction.suggested)
                            .foregroundStyle(.primary)
                    }

                    Spacer()

                    if !correction.from.isEmpty, !correction.to.isEmpty {
                        Button("存为规则") {
                            state.addRule(find: correction.from, replace: correction.to)
                            resultNote = "已把「\(correction.from)→\(correction.to)」存入纠错词典"
                        }
                        .buttonStyle(.link)
                        .help("以后识别到「\(correction.from)」自动替换")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .finished(let count) = state.proofread, count > 0 {
                Button("全选") {
                    state.acceptedCorrections = Set(state.corrections.map(\.id))
                }
                Button("全不选") { state.acceptedCorrections = [] }
            }

            if let resultNote {
                Text(resultNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            switch state.proofread {
            case .running:
                ProgressView().controlSize(.small)
            case .finished(let count) where count > 0:
                Button("重新校对") { state.startProofread() }
                Button("应用选中的 \(state.acceptedCorrections.count) 处") {
                    let result = state.applyAcceptedCorrections(undoManager: undoManager)
                    resultNote =
                        result.skipped > 0
                        ? "已修改 \(result.applied) 句,\(result.skipped) 句因已被手动编辑而跳过"
                        : "已修改 \(result.applied) 句"
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.acceptedCorrections.isEmpty)
            default:
                Button("开始校对") { state.startProofread() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canProofread || state.llmAPIKey.isEmpty)
            }

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private func timeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}
