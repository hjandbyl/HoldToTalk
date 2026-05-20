// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HoldToTalk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HoldToTalk", targets: ["HoldToTalk"])
    ],
    targets: [
        .executableTarget(
            name: "HoldToTalk",
            dependencies: ["CSherpaOnnx"],
            path: "HoldToTalk",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .target(
            name: "CSherpaOnnx",
            path: "CSherpaOnnx",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-L", "ThirdParty/sherpa-onnx-v1.13.0-onnxruntime-1.24.4-osx-arm64-shared/lib",
                    "-lsherpa-onnx-c-api",
                    "-lonnxruntime",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
