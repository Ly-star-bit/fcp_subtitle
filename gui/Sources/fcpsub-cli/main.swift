import FCPSubtitleCore
import Foundation

// Headless smoke-test CLI: same pipeline as the GUI, no window.
// Usage: fcpsub-cli <audio> <models-dir> [output.fcpxml] [--fps 25]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "用法: fcpsub-cli <音频文件> <models目录> [输出.fcpxml] [--fps 25]\n".data(using: .utf8)!)
    exit(1)
}

let audioURL = URL(fileURLWithPath: args[1])
let modelsDir = URL(fileURLWithPath: args[2])
var outputPath = audioURL.deletingPathExtension().appendingPathExtension("fcpxml").path
var fps = "25"
var format = SubtitleFormat.fcpxml
var maxChars = 0  // 0 = no splitting
var language = ""

var i = 3
while i < args.count {
    if args[i] == "--fps", i + 1 < args.count {
        fps = args[i + 1]
        i += 2
    } else if args[i] == "--srt" {
        format = .srt
        i += 1
    } else if args[i] == "--format", i + 1 < args.count {
        guard let f = SubtitleFormat(rawValue: args[i + 1]) else {
            FileHandle.standardError.write(
                "不支持的格式: \(args[i + 1]),可选: \(SubtitleFormat.allCases.map(\.rawValue).joined(separator: "/"))\n"
                    .data(using: .utf8)!)
            exit(1)
        }
        format = f
        i += 2
    } else if args[i] == "--max-chars", i + 1 < args.count {
        maxChars = Int(args[i + 1]) ?? 0
        i += 2
    } else if args[i] == "--lang", i + 1 < args.count {
        language = args[i + 1]
        i += 2
    } else {
        outputPath = args[i]
        i += 1
    }
}

let models = ModelPaths(
    senseVoiceModel: modelsDir.appendingPathComponent("sense-voice/model.int8.onnx").path,
    tokens: modelsDir.appendingPathComponent("sense-voice/tokens.txt").path,
    sileroVad: modelsDir.appendingPathComponent("silero_vad.onnx").path)

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        let clock = ContinuousClock()
        let startTime = clock.now
        var segments: [SubtitleSegment]
        if audioURL.pathExtension.lowercased() == "srt" {
            segments = SRTParser.parse(try String(contentsOf: audioURL, encoding: .utf8))
        } else {
            let samples = try await AudioDecoder.decode(url: audioURL)
            segments = try Transcriber.transcribe(
                samples: samples, models: models, language: language)
        }
        if maxChars > 0 {
            segments = SegmentSplitter.split(segments, maxChars: maxChars)
        }
        let elapsed = clock.now - startTime

        for seg in segments {
            print(String(format: "[%8.3f -> %8.3f] %@", seg.start, seg.end, seg.text))
        }

        let content = SubtitleExporter.export(segments: segments, format: format, fps: fps)
        if format != .fcpxml, outputPath.hasSuffix(".fcpxml") {
            outputPath = String(outputPath.dropLast(7)) + "." + format.fileExtension
        }
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("识别 \(segments.count) 句,耗时 \(elapsed)")
        print("已生成: \(outputPath)")
    } catch {
        FileHandle.standardError.write("错误: \(error.localizedDescription)\n".data(using: .utf8)!)
        exitCode = 1
    }
    semaphore.signal()
}

semaphore.wait()
exit(exitCode)
