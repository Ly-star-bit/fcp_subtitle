import SwiftUI

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        Form {
            Section("模型") {
                ForEach(ModelStore.items) { item in
                    modelRow(item)
                }
            }

            Section("下载设置") {
                Toggle("使用国内镜像 (hf-mirror.com)", isOn: store.$useHFMirror)
                Toggle("使用代理", isOn: store.$useProxy)
                if store.useProxy {
                    TextField("代理地址", text: store.$proxyURL, prompt: Text("http://主机:端口"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }

            Section("存储位置") {
                HStack {
                    Text(ModelStore.downloadDir.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("在访达中显示") { store.revealInFinder() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }

    @ViewBuilder
    private func modelRow(_ item: ModelItem) -> some View {
        let state = store.states[item.id] ?? .notInstalled
        let totalSize = item.files.map(\.sizeHint).joined(separator: " + ")

        HStack(alignment: .center, spacing: 12) {
            statusIcon(state)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text("\(item.detail) · \(totalSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            switch state {
            case .downloading(let fraction):
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                    if let info = store.downloadInfo[item.id],
                        !info.speedText.isEmpty
                    {
                        Text("\(info.speedText) · \(info.etaText)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                Button {
                    store.cancelDownload(item)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("取消下载")
            case .notInstalled, .failed:
                Button("下载") { store.download(item) }
            case .bundled:
                Text("已内置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重新下载") { store.download(item) }
            case .downloaded:
                Text("已下载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重新下载") { store.download(item) }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ state: ModelStore.ItemState) -> some View {
        switch state {
        case .bundled, .downloaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .notInstalled:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// Shown wherever recognition is blocked on the model (empty window, files
/// waiting in the queue): one button fetches everything missing, progress
/// shows in place, and the download settings are one click away if it fails.
struct ModelSetupCard: View {
    @ObservedObject private var store = ModelStore.shared
    @EnvironmentObject private var router: TabRouter

    var body: some View {
        VStack(spacing: 10) {
            Label("首次使用需要下载识别模型（约 \(store.missingSizeText)）", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("只需下载一次，之后识别全程离线。默认走国内镜像 hf-mirror.com。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let progress = store.setupProgress {
                ProgressView(value: progress)
                    .frame(width: 280)
                HStack(spacing: 10) {
                    Text("下载中 \(Int(progress * 100))%  \(store.setupStatusText)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("取消") { store.cancelAllDownloads() }
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 10) {
                    Button("下载模型") { store.downloadMissing() }
                        .buttonStyle(.borderedProminent)
                    Button("下载设置…") { router.selection = 1 }
                        .help("代理、镜像等设置在「模型管理」页")
                }
                if let error = store.setupError {
                    Text("下载失败：\(error)。可以在「下载设置」里换镜像或开代理后重试。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}
