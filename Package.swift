// swift-tools-version: 6.3
import PackageDescription

let swift6Settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let releaseSettings: [SwiftSetting] = [
    // The binaries are small and mostly serial; whole-module optimization lets
    // the release compiler inline across the CLI/Core boundary.
    .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
]

let package = Package(
    name: "pdfmd",
    // Target: macOS 26+ with an opportunistic macOS 27 multimodal repair
    // path (plan.md section 2.1). The 27-only call sites sit behind
    // `if #available(macOS 27, *)`; the floor stays at 26.0.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PdfmdCore", targets: ["PdfmdCore"]),
        .executable(name: "pdfmd", targets: ["pdfmd"]),
        .executable(name: "pdfmd-bench", targets: ["pdfmd-bench"]),
    ],
    targets: [
        .target(
            name: "PdfmdCore",
            path: "Sources/PdfmdCore",
            swiftSettings: swift6Settings + releaseSettings
        ),
        .executableTarget(
            name: "pdfmd",
            dependencies: ["PdfmdCore"],
            path: "Sources/pdfmd",
            swiftSettings: swift6Settings + releaseSettings
        ),
        .executableTarget(
            name: "pdfmd-bench",
            dependencies: ["PdfmdCore"],
            path: "Sources/pdfmd-bench",
            swiftSettings: swift6Settings + releaseSettings
        ),
        .testTarget(
            name: "PdfmdCoreTests",
            dependencies: ["PdfmdCore"],
            path: "Tests/PdfmdCoreTests",
            swiftSettings: swift6Settings
        ),
    ]
)
