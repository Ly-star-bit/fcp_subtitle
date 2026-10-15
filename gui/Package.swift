// swift-tools-version:5.9
import PackageDescription

// Absolute, so dev builds (.build/release/fcpsub-cli) run from any directory.
// package_app.sh strips this rpath from the shipped app.
let vendorLib = Context.packageDirectory + "/Vendor/sherpa-onnx/lib"

let sherpaLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .unsafeFlags([
        "-L", vendorLib,
        "-lsherpa-onnx-c-api",
        "-lonnxruntime",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", vendorLib,
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
