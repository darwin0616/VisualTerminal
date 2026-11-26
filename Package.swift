// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisualTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VisualTerminalCore", targets: ["VisualTerminalCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.105.0"),
    ],
    targets: [
        .target(name: "VisualTerminalCore", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        // 指令列小工具：用來測試 SSH 核心（連線、執行、讀輸出）
        .executableTarget(name: "vt-probe", dependencies: ["VisualTerminalCore"]),
        // 驗證 App 的 SessionModel（符號連結到 App/VisualTerminal/SessionModel.swift）
        .executableTarget(name: "vt-model-probe", dependencies: ["VisualTerminalCore"]),
        // 驗證 App 的 Blocks / WorkspaceModel（符號連結）
        .executableTarget(name: "vt-blocks-probe", dependencies: ["VisualTerminalCore"]),
        .testTarget(name: "VisualTerminalCoreTests", dependencies: ["VisualTerminalCore"]),
    ]
)
