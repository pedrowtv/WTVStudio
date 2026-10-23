// swift-tools-version: 6.0
import PackageDescription

// Alvos de tempo real (vídeo, áudio, entradas, saídas) compilam em modo de linguagem Swift 5
// (decisão D18 em docs/ARQUITECTURA.md); a camada de controlo usa Swift 6 com actors.
let realtimeSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "wtv-engine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wtv-engine", targets: ["wtv-engine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift.git", exact: "2.2.5"),
    ],
    targets: [
        .target(name: "WTVProtocol"),
        .target(name: "CNDI"),
        .target(
            name: "WTVCore",
            dependencies: [
                "WTVProtocol",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "WTVVideo", dependencies: ["WTVCore"], swiftSettings: realtimeSettings),
        .target(name: "WTVAudio", dependencies: ["WTVCore"], swiftSettings: realtimeSettings),
        .target(name: "WTVInputs", dependencies: ["WTVCore", "WTVVideo", "WTVAudio", "WTVOutputs", "CNDI", .product(name: "SRTHaishinKit", package: "HaishinKit.swift")], swiftSettings: realtimeSettings),
        .target(
            name: "WTVOutputs",
            dependencies: [
                "WTVCore", "WTVVideo", "WTVAudio", "CNDI",
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift"),
            ],
            swiftSettings: realtimeSettings
        ),
        .target(
            name: "WTVServer",
            dependencies: [
                "WTVCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .executableTarget(
            name: "wtv-engine",
            dependencies: [
                "WTVCore", "WTVServer", "WTVVideo", "WTVAudio", "WTVInputs", "WTVOutputs",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "WTVCoreTests", dependencies: ["WTVCore", "WTVAudio"]),
    ]
)
