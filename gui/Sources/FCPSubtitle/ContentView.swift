import FCPSubtitleCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var state = AppState.shared
    @StateObject private var previewPlayer = PreviewPlayer()
    @EnvironmentObject private var router: TabRouter
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var replaceResult: String?
    @State private var hoveredRowID: UUID?
    @State private var selectedSegmentID: UUID?
    @State private var showDictionary = false
    @State private var showProofread = false
    @FocusState private var findFieldFocused: Bool

    private var modelsMissing: Bool { ModelStore.locateModels() == nil }

    var body: some View {
        Group {
            if state.files.isEmpty {
                dropZone
            } else {
                mainInterface
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        // Sheets get the main window's undo manager so their edits stay
        // undoable after the sheet closes.
        .sheet(isPresented: $showDictionary) {
            DictionarySheet(undoManager: undoManager)
        }
        .sheet(isPresented: $showProofread) {
            ProofreadSheet(undoManager: undoManager)
        }
        .background(hiddenShortcuts)
    }

    // MARK: - Keyboard proofreading flow

    private var hiddenShortcuts: some View {
        Group {
            Button("") { moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("") { playSelected() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { findFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func moveSelection(by delta: Int) {
        guard let file = state.selectedFile, !file.segments.isEmpty else { return }
        let segments = file.segments
        let currentIndex = segments.firstIndex { $0.id == selectedSegmentID } ?? -delta
        let next = min(max(currentIndex + delta, 0), segments.count - 1)
        selectedSegmentID = segments[next].id
        NotificationCenter.default.post(name: .jumpToSegment, object: selectedSegmentID)
    }

    private func playSelected() {
        guard let file = state.selectedFile, !file.isSubtitleImport,
            let seg = file.segments.first(where: { $0.id == selectedSegmentID })
        else { return }
        previewPlayer.toggle(url: file.url, segment: seg)
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in state.enqueue(urls: [url]) }
                }
            }
        }
        return true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.audio, .movie]
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            state.enqueue(urls: panel.urls)
        }
    }

    // MARK: - Empty state

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 56))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                .scaleEffect(dropTargeted ? 1.15 : 1.0)
                .animation(.spring(duration: 0.25), value: dropTargeted)
            Text("把音频、视频或 SRT 字幕拖到这里")
                .font(.title2)
            Text("支持多个文件 · wav / m4a / mp3 / mp4 / mov / srt · 全程本地")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("选择文件…") { pickFiles() }
                .keyboardShortcut("o")

            if modelsMissing {
                VStack(spacing: 8) {
                    Label("尚未安装识别模型(SRT 转换不受影响)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("去下载模型") { router.selection = 1 }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8]))
                .padding(20)
                .animation(.easeInOut(duration: 0.15), value: dropTargeted)
        )
    }

    // MARK: - Main interface

    private var mainInterface: some View {
        VStack(spacing: 0) {
            fileBar
            Divider()
            selectedFileArea
            Divider()
            bottomBar
        }
    }

    private var fileBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(state.files) { file in
                    fileChip(file)
                }
                Button {
                    pickFiles()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("添加文件")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func fileChip(_ file: QueueFile) -> some View {
        let isSelected = state.selectedFileID == file.id
        return HStack(spacing: 6) {
            chipIcon(file.status)
            Text(file.name)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button {
                state.removeFile(id: file.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.selectedFileID = file.id }
    }

    @ViewBuilder
    private func chipIcon(_ status: QueueFile.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .decoding, .transcribing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var selectedFileArea: some View {
        if let file = state.selectedFile {
            switch file.status {
            case .pending:
                centerMessage("排队中…", icon: "clock")
            case .decoding(let fraction):
                workingView(stage: "解码音频", fraction: fraction, file: file, showETA: false)
            case .transcribing(let fraction):
                workingView(stage: "识别", fraction: fraction, file: file, showETA: true)
            case .failed(let message):
                failedView(message, fileID: file.id)
            case .done:
                resultView(file)
            }
        } else {
            centerMessage("选择上方的文件查看结果", icon: "hand.point.up")
        }
    }

    private func centerMessage(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workingView(stage: String, fraction: Double, file: QueueFile, showETA: Bool) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: fraction)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                Text("\(stage)中… \(Int(fraction * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if showETA {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if let eta = state.eta(for: file) {
                            Text("· \(eta)").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Text(file.name).font(.caption).foregroundStyle(.tertiary)
            Button("取消") { state.cancelCurrent() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String, fileID: UUID) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("重试") { state.retry(id: fileID) }
                if message.contains("模型") {
                    Button("去下载模型") { router.selection = 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private func resultView(_ file: QueueFile) -> some View {
        VStack(spacing: 0) {
            findReplaceBar
            timelineStrip(file)
            ScrollViewReader { proxy in
                List(selection: $selectedSegmentID) {
                    ForEach(segmentBindings(fileID: file.id)) { $seg in
                        let index = file.segments.firstIndex { $0.id == seg.id } ?? 0
                        segmentRow(index: index, seg: $seg, file: file)
                            .id(seg.id)
                            .tag(seg.id)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .jumpToSegment)) { note in
                    if let id = note.object as? UUID {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            HStack {
                let timeline = state.timelineFormat(for: file)
                Text("\(file.segments.count) 句"
                    + (file.isSubtitleImport
                        ? " · 从 SRT 导入" : " · 识别耗时 \(String(format: "%.1f", file.elapsed))s")
                    + " · 时间线 \(timeline.label)\(timeline.followsSource ? "(跟随视频)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("⌘↑/⌘↓ 选句 · ⌘↩ 试听 · 右键行可合并/拆分 · ⌘Z 撤销")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func segmentBindings(fileID: UUID) -> Binding<[SubtitleSegment]> {
        Binding(
            get: { state.files.first { $0.id == fileID }?.segments ?? [] },
            set: { newValue in
                if let index = state.files.firstIndex(where: { $0.id == fileID }) {
                    state.files[index].segments = newValue
                    state.scheduleSave()
                }
            }
        )
    }

    private func segmentRow(index: Int, seg: Binding<SubtitleSegment>, file: QueueFile) -> some View {
        let isPlaying = previewPlayer.playingID == seg.wrappedValue.id
        let isHovered = hoveredRowID == seg.wrappedValue.id
        let isSelected = selectedSegmentID == seg.wrappedValue.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !file.isSubtitleImport {
                Button {
                    previewPlayer.toggle(url: file.url, segment: seg.wrappedValue)
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "停止" : "试听这一句 (⌘↩)")
            }

            Text(timeLabel(seg.wrappedValue.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)

            TextField("字幕", text: seg.text, axis: .vertical)
                .textFieldStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.15)
                        : isHovered
                            ? Color.accentColor.opacity(0.08)
                            : (index % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear))
        )
        .onHover { hovering in
            hoveredRowID = hovering ? seg.wrappedValue.id : nil
        }
        .contextMenu {
            Button("与上一句合并") {
                state.mergeWithPrevious(
                    fileID: file.id, segmentID: seg.wrappedValue.id, undoManager: undoManager)
            }
            .disabled(index == 0)
            Button("按标点拆分") {
                state.splitAtPunctuation(
                    fileID: file.id, segmentID: seg.wrappedValue.id, undoManager: undoManager)
            }
            Divider()
            timeNudgeMenu(file: file, seg: seg.wrappedValue)
            Divider()
            Button("删除这一句", role: .destructive) {
                state.deleteSegment(
                    fileID: file.id, segmentID: seg.wrappedValue.id, undoManager: undoManager)
            }
        }
    }

    @ViewBuilder
    private func timeNudgeMenu(file: QueueFile, seg: SubtitleSegment) -> some View {
        Menu("调整时间") {
            Button("提前出现 0.1s") { nudge(file, seg, start: -0.1, duration: 0.1) }
            Button("延后出现 0.1s") { nudge(file, seg, start: 0.1, duration: -0.1) }
            Button("延长 0.2s") { nudge(file, seg, start: 0, duration: 0.2) }
            Button("缩短 0.2s") { nudge(file, seg, start: 0, duration: -0.2) }
        }
    }

    private func nudge(_ file: QueueFile, _ seg: SubtitleSegment, start: Double, duration: Double) {
        state.nudge(
            fileID: file.id, segmentID: seg.id, startDelta: start, durationDelta: duration,
            undoManager: undoManager)
    }

    private var findReplaceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("查找", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
                .focused($findFieldFocused)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption)
            TextField("替换为", text: $replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
            Button("全部替换") {
                let n = state.replaceAll(find: findText, replace: replaceText, undoManager: undoManager)
                replaceResult = "已替换 \(n) 处"
            }
            .disabled(findText.isEmpty)
            Button("存为规则") {
                state.addRule(find: findText, replace: replaceText)
                replaceResult = "已存入词典"
            }
            .disabled(findText.isEmpty)
            .help("下次识别自动应用这条替换")
            if let replaceResult {
                Text(replaceResult).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showProofread = true
            } label: {
                Label("AI 校对", systemImage: "sparkles")
            }
            .disabled(!state.canProofread)
            .help("用大模型检查同音错别字,逐条确认后再应用")
            Button {
                showDictionary = true
            } label: {
                Label("纠错词典 (\(state.dictionary.count))", systemImage: "character.book.closed")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func timelineStrip(_ file: QueueFile) -> some View {
        let total = max(file.segments.map(\.end).max() ?? 1, 0.001)
        return ZStack(alignment: .leading) {
            // Waveform behind the segment blocks
            if !file.peaks.isEmpty {
                Canvas { context, size in
                    let count = file.peaks.count
                    let step = size.width / CGFloat(count)
                    for (i, peak) in file.peaks.enumerated() {
                        let h = max(CGFloat(peak) * size.height, 1)
                        let rect = CGRect(
                            x: CGFloat(i) * step, y: (size.height - h) / 2,
                            width: max(step - 0.5, 0.5), height: h)
                        context.fill(Path(rect), with: .color(Color.secondary.opacity(0.25)))
                    }
                }
            }
            GeometryReader { geo in
                ForEach(file.segments) { seg in
                    let x = seg.start / total * geo.size.width
                    let w = max(seg.duration / total * geo.size.width, 2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            selectedSegmentID == seg.id
                                ? Color.accentColor : Color.accentColor.opacity(0.5))
                        .frame(width: w, height: 8)
                        .offset(x: x, y: 14)
                        .onTapGesture {
                            selectedSegmentID = seg.id
                            NotificationCenter.default.post(name: .jumpToSegment, object: seg.id)
                        }
                        .help(seg.text)
                }
            }
        }
        .frame(height: 36)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Picker("语言", selection: $state.language) {
                ForEach(AppState.languages, id: \.code) { Text($0.label).tag($0.code) }
            }
            .frame(width: 120)
            .help("识别语言,粤语/日语素材指定后更准")

            timelineMenu

            Toggle("断句", isOn: $state.splitLongLines)
                .help("超过字数上限的长句按标点自动拆分")
            if state.splitLongLines {
                Stepper("≤\(state.maxLineChars)字", value: $state.maxLineChars, in: 8...40)
            }

            Spacer()

            if let export = state.lastExport {
                Button {
                    state.revealLastExport()
                } label: {
                    Label(export.label, systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .help("在访达中显示")
            }

            Picker("格式", selection: $state.exportFormat) {
                ForEach(SubtitleFormat.allCases, id: \.rawValue) { format in
                    Text(format.displayName).tag(format.rawValue)
                }
            }
            .frame(width: 210)

            Button("全部导出") { state.exportAll() }
                .disabled(!state.files.contains { $0.status == .done })
            Button("导出当前") { state.exportSelected() }
                .keyboardShortcut("s")
                .disabled(state.selectedFile?.status != .done)
            Button {
                state.sendSelectedToFCP()
            } label: {
                Label("发送到 FCP", systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("e")
            .buttonStyle(.borderedProminent)
            .disabled(state.selectedFile?.status != .done)
            .help("直接交给 Final Cut Pro 打开导入对话框,不用先存文件")
        }
        .padding(12)
    }

    /// FCPXML timeline settings: follow each video's own size and rate, or
    /// the manual rate/size (always used for audio and SRT files).
    private var timelineMenu: some View {
        Menu {
            Toggle("跟随视频素材的尺寸和帧率", isOn: $state.matchSourceFormat)
            Divider()
            Picker("帧率", selection: $state.fps) {
                ForEach(FCPXMLBuilder.fpsLabels, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("画面尺寸", selection: $state.timelineSize) {
                ForEach(AppState.timelineSizes, id: \.id) { Text($0.label).tag($0.id) }
            }
        } label: {
            Text(state.matchSourceFormat ? "时间线: 跟随素材" : "时间线: \(state.fps)p")
        }
        .fixedSize()
        .help("导出 FCPXML 的画面尺寸和帧率。跟随素材时视频按自身格式导出,音频/SRT 用手动设置")
    }

    private func timeLabel(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}

// MARK: - Dictionary management sheet

struct DictionarySheet: View {
    let undoManager: UndoManager?
    @ObservedObject private var state = AppState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newFind = ""
    @State private var newReplace = ""
    @State private var applyResult: String?

    init(undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("纠错词典").font(.headline)
                Spacer()
                Toggle("识别后自动应用", isOn: $state.autoApplyDictionary)
            }
            .padding()

            Divider()

            if state.dictionary.isEmpty {
                Text("还没有规则。识别出错别字后,在查找替换栏点「存为规则」,\n或在下方直接添加(如:字母 → 字幕)。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.dictionary) { rule in
                        HStack {
                            Text(rule.find)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(rule.replace.isEmpty ? "(删除)" : rule.replace)
                            Spacer()
                            Button {
                                state.removeRule(id: rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("错词", text: $newFind)
                    .textFieldStyle(.roundedBorder)
                TextField("正确写法", text: $newReplace)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    state.addRule(find: newFind, replace: newReplace)
                    newFind = ""
                    newReplace = ""
                }
                .disabled(newFind.isEmpty)
            }
            .padding()

            HStack {
                Button("立即应用到当前文件") {
                    let n = state.applyDictionaryToSelected(undoManager: undoManager)
                    applyResult = "已替换 \(n) 处"
                }
                .disabled(state.dictionary.isEmpty || state.selectedFile?.status != .done)
                if let applyResult {
                    Text(applyResult).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 460, height: 400)
    }
}

extension Notification.Name {
    static let jumpToSegment = Notification.Name("jumpToSegment")
}
