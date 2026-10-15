import FCPSubtitleCore
import SwiftUI

/// 字幕设置 (⌘,): how lines are broken and punctuated, display timing,
/// hotwords, and the FCPXML title style. Settings that are chosen once live
/// here so the main window keeps only per-job controls.
struct SettingsView: View {
    @ObservedObject private var state = AppState.shared

    private static let commonFonts = [
        "PingFang SC", "Hiragino Sans GB", "Songti SC", "Kaiti SC", "STHeiti", "Helvetica Neue",
    ]

    var body: some View {
        Form {
            Section {
                Stepper("每行最多 \(state.maxLineChars) 个字", value: $state.maxLineChars, in: 8...40)
                Picker("标点", selection: $state.punctuationStyle) {
                    ForEach(PunctuationStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                Toggle("优化显示时长", isOn: $state.optimizeTiming)
                Text("每句至少显示 0.8 秒；相邻两句间隔不到半秒时自动衔接，避免字幕一闪一闪。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("断句与标点")
            } footer: {
                Text("对之后识别的文件生效；已识别的文件在结果页点「重新断句」即可套用（可撤销）。英文和数字按半个字计算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $state.hotwordsText)
                    .font(.body)
                    .frame(height: 90)
                Text("每行一个专有名词，如：剪映、达芬奇、Final Cut Pro。识别后读音相同的错字会改成这里的写法（简映 → 剪映），英文统一大小写。只填专有名词——像「字幕」这样的常用词，会把读音相同的「字母」也改掉。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("热词")
            }

            Section {
                HStack {
                    TextField("字体", text: $state.fontName)
                    Menu("常用字体") {
                        ForEach(Self.commonFonts, id: \.self) { font in
                            Button(font) { state.fontName = font }
                        }
                    }
                    .fixedSize()
                }
                Stepper("字号 \(state.fontSize)", value: $state.fontSize, in: 20...200, step: 2)
            } header: {
                Text("FCPXML 字幕样式")
            } footer: {
                Text("导出到 Final Cut Pro 的 Basic Title 使用的字体和字号，导入后仍可在 FCP 里批量修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
