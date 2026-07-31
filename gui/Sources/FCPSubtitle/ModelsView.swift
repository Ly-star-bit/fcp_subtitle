import SwiftUI

struct ModelsView: View {
    @StateObject private var store = ModelStore()

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
