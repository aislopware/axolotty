// swift-tools-version: 6.2
// Axolotty — the shared package. Everything except the two app shells lives here and is
// tested with `swift test` on the Mac. App bundles (macOS AppKit, iOS UIKit) come from
// App/project.yml (XcodeGen) and link these libraries.
import PackageDescription

/// Swift 6 plus every upcoming feature that 6.4 marks for the next language mode.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .treatAllWarnings(as: .error),
]

/// UI modules run on the main actor by default (SE-0466); core modules never do.
let ui: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let cStrict: [CSetting] = [
    .unsafeFlags(["-std=c23", "-Wall", "-Wextra", "-Wpedantic", "-Wconversion", "-Wshadow", "-Werror"])
]

let macOnly: TargetDependencyCondition? = .when(platforms: [.macOS])

let package = Package(
    name: "Axolotty",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "AxolottyKit", targets: ["AxModel", "AxProtocol", "AxVT", "AxClient", "AxRender"]),
        .library(name: "AxMacUI", targets: ["AxMacUI"]),
        .executable(name: "axolottyd", targets: ["axolottyd"]),
        .executable(name: "axolotty-ptyd", targets: ["axolotty-ptyd"]),
        .executable(name: "axolotty", targets: ["axolotty"]),
    ],
    targets: [
        // MARK: Native
        .binaryTarget(name: "GhosttyVT", path: "Vendor/GhosttyVT.xcframework"),
        // Plaintext QUIC over the tailnet (Rust/axquic, built by scripts/build-axquic.sh).
        .binaryTarget(name: "AxQuic", path: "Vendor/AxQuic.xcframework"),
        .target(name: "AxSys", cSettings: cStrict),  // macOS: pty spawn, libproc
        .target(name: "AxText", cSettings: cStrict),  // portable byte scanning
        .target(name: "AxFrame", dependencies: ["GhosttyVT"], cSettings: cStrict),  // render hot path

        // MARK: Portable core (macOS + iOS, no AppKit/UIKit)
        .target(name: "AxModel", swiftSettings: strict),
        .target(name: "AxVT", dependencies: ["GhosttyVT"], swiftSettings: strict),
        .target(name: "AxProtocol", dependencies: ["AxModel", .target(name: "AxQuic", condition: macOnly)],
                swiftSettings: strict),
        .target(name: "AxClient", dependencies: ["AxModel", "AxProtocol", "AxVT"], swiftSettings: strict),
        .target(name: "AxRender", dependencies: ["AxVT", "AxFrame", "AxModel", "GhosttyVT"], swiftSettings: strict),

        // MARK: Host side (macOS)
        .target(
            name: "AxHost",
            dependencies: ["AxModel", "AxProtocol", "AxVT", "AxText", .target(name: "AxSys", condition: macOnly)],
            swiftSettings: strict),
        .executableTarget(name: "axolottyd", dependencies: ["AxHost"], swiftSettings: strict),
        // The PTY holder: plain C, one kqueue loop, never parses output (see docs/ARCHITECTURE.md).
        .executableTarget(name: "axolotty-ptyd", dependencies: ["AxSys"], cSettings: cStrict),
        .executableTarget(name: "axolotty", dependencies: ["AxClient", "AxProtocol", "AxModel", "AxVT"], swiftSettings: strict),

        // MARK: UI
        .target(name: "AxMacUI", dependencies: ["AxClient", "AxRender", "AxModel", "AxVT", "AxProtocol"],
                resources: [.copy("Resources/Fonts")], swiftSettings: ui),
        // `swift run AxolottyDev`: the app without Xcode (dev loop). The shipping bundle comes from App/project.yml.
        // (Not "Axolotty": on case-insensitive volumes it would collide with the `axolotty` CLI.)
        .executableTarget(name: "AxolottyDev", dependencies: ["AxMacUI"], path: "Sources/AxolottyApp", swiftSettings: ui),

        // MARK: Tests (none link AppKit/UIKit; Metal pixel tests live in AxRenderTests behind a tag)
        .target(name: "AxTestSupport", dependencies: ["AxModel", "AxProtocol", "AxVT"], path: "Tests/AxTestSupport",
                swiftSettings: strict),
        .testTarget(name: "AxNativeTests", dependencies: ["AxText", .target(name: "AxSys", condition: macOnly)],
                    swiftSettings: strict),
        .testTarget(name: "AxModelTests", dependencies: ["AxModel", "AxTestSupport"], swiftSettings: strict),
        .testTarget(name: "AxVTTests", dependencies: ["AxVT", "AxTestSupport"], resources: [.copy("Fixtures")],
                    swiftSettings: strict),
        .testTarget(name: "AxProtocolTests", dependencies: ["AxProtocol", "AxTestSupport"], swiftSettings: strict),
        .testTarget(name: "AxHostTests", dependencies: ["AxHost", "AxClient", "AxTestSupport"], swiftSettings: strict),
        .testTarget(name: "AxRenderTests", dependencies: ["AxRender", "AxTestSupport"], swiftSettings: strict),
    ]
)
