// swift-tools-version: 6.0

import PackageDescription

// Direct composition and retained platform helpers; shared business packages remain separate.
let package = Package(
    name: "cmuxFeature",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "cmuxFeature",
            targets: ["cmuxFeature"]
        ),

    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CmuxIrohTransport"),
        .package(path: "../../Packages/Shared/CmuxIrxTransport"),
        .package(path: "../../Packages/Shared/CMUXMobileCore"),
        .package(path: "../../Packages/iOS/CmuxMobileCamera"),
        .package(path: "../../Packages/iOS/CmuxMobileDiagnostics"),
        .package(path: "../../Packages/iOS/CmuxMobilePairedMac"),
        .package(path: "../../Packages/iOS/CmuxMobileRPC"),
        .package(path: "../../Packages/iOS/CmuxMobileShell"),
        .package(path: "../../Packages/iOS/CmuxMobileShellModel"),
        .package(path: "../../Packages/iOS/CmuxMobileShellUI"),
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxMobileTerminal"),
        .package(path: "../../Packages/iOS/CmuxMobileToast"),
        .package(path: "../../Packages/iOS/CmuxMobileTerminalKit"),
        .package(path: "../../Packages/iOS/CmuxMobileTransport"),
        .package(path: "../../Packages/iOS/CmuxMobileWorkspace"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "cmuxFeature",
            dependencies: [
                "CMUXMobileCore",
                "CmuxMobileCamera",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileShellUI",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileToast",
                "CmuxMobileTransport",
                "CmuxMobileWorkspace",
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),

        .testTarget(
            name: "cmuxFeatureTests",
            dependencies: [
                "cmuxFeature",
                "CMUXAuthCore",
                "CmuxAuthRuntime",
                "CmuxIrohTransport",
                "CmuxIrxTransport",
                "CMUXMobileCore",
                "CmuxMobileCamera",
                "CmuxMobileDiagnostics",
                "CmuxMobilePairedMac",
                "CmuxMobileRPC",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
                "CmuxMobileShellUI",
                "CmuxMobileSupport",
                "CmuxMobileTerminal",
                "CmuxMobileTerminalKit",
                "CmuxMobileToast",
                "CmuxMobileTransport",
                "CmuxMobileWorkspace",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
    ]
)
