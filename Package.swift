// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "dappermap",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DapperMapCore", targets: ["DapperMapCore"]),
        .library(name: "DapperMapEngine", targets: ["DapperMapEngine"]),
        // The existing AppKit/CoreGraphics frontend.
        .executable(name: "dappermap", targets: ["dappermap"]),
        // The portable SDL2 frontend.
        .executable(name: "dappermap-sdl", targets: ["dappermap-sdl"])
    ],
    dependencies: [
        .package(url: "https://github.com/picawawa4000/dpreader-swift.git", branch: "master"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", exact: "0.56.0")
    ],
    targets: [
        .target(
            name: "DapperMapCore",
            path: "Sources/Common"
        ),
        .systemLibrary(
            name: "SDL2",
            pkgConfig: "sdl2",
            providers: [
                .brew(["sdl2"]),
                .apt(["libsdl2-dev"])
            ]
        ),
        .target(
            name: "DapperMapEngine",
            dependencies: [
                "DapperMapCore",
                .product(name: "DPReader", package: "dpreader-swift"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit")
            ],
            path: "Sources/App",
            exclude: ["NativeAppController.swift", "NativeMapView.swift"]
        ),
        .target(
            name: "DapperMapAppKit",
            dependencies: [
                "DapperMapCore",
                "DapperMapEngine",
                .product(name: "DPReader", package: "dpreader-swift")
            ],
            path: "Sources/App",
            exclude: [
                "AppDefaults.swift", "AppModels.swift", "BrowserApp.swift", "BrowserWASMRuntime.swift",
                "NativeGenerationPlatform.swift", "TileGenerationService.swift"
            ],
            sources: ["NativeAppController.swift", "NativeMapView.swift"]
        ),
        .executableTarget(
            name: "dappermap",
            dependencies: [
                "DapperMapEngine",
                "DapperMapAppKit",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit")
            ],
            path: "Sources",
            exclude: ["App", "Common", "SDL", "benchstart"],
            sources: ["main.swift"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                .unsafeFlags(
                    [
                        "-Osize",
                        "-gnone"
                    ],
                    .when(platforms: [.wasi])
                )
            ],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "--strip-all",
                        // WebKit can retain stale bounds for a shared WASM memory while another
                        // instance grows it. Keep tile generation below the initial allocation so
                        // the main instance and its worker never have to coordinate a grow.
                        "-Xlinker", "--initial-memory=134217728"
                    ],
                    .when(platforms: [.wasi])
                )
            ]
        ),
        .executableTarget(
            name: "dappermap-sdl",
            dependencies: ["DapperMapCore", "DapperMapEngine", "SDL2"],
            path: "Sources/SDL"
        ),
        .executableTarget(
            name: "benchstart",
            dependencies: [
                .product(name: "DPReader", package: "dpreader-swift")
            ],
            path: "Sources/benchstart"
        ),
        .testTarget(
            name: "DapperMapTests",
            dependencies: ["DapperMapCore"],
            path: "Tests"
        ),
    ]
)
