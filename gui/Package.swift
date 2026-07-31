// swift-tools-version:5.9
import PackageDescription

let sherpaLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .unsafeFlags([
        "-L", "Vendor/sherpa-onnx/lib",
        "-lsherpa-onnx-c-api",
        "-lonnxruntime",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "Vendor/sherpa-onnx/lib",
    ]),
]

let package = Package(
    name: "FCPSubtitle",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "SherpaOnnxC", path: "Sources/SherpaOnnxC"),
        .target(
            name: "FCPSubtitleCore",
            dependencies: ["SherpaOnnxC"],
            swiftSettings: [.unsafeFlags(["-I", "Vendor/sherpa-onnx/include"])]
        ),
        .executableTarget(
            name: "FCPSubtitle",
            dependencies: ["FCPSubtitleCore"],
            swiftSettings: [.unsafeFlags(["-I", "Vendor/sherpa-onnx/include"])],
            linkerSettings: sherpaLinkerSettings
        ),
        .executableTarget(
            name: "fcpsub-cli",
            dependencies: ["FCPSubtitleCore"],
            swiftSettings: [.unsafeFlags(["-I", "Vendor/sherpa-onnx/include"])],
            linkerSettings: sherpaLinkerSettings
        ),
    ]
)
