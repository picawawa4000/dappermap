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
            path: "Sources/Common",
            swiftSettings: [
                .unsafeFlags(
                    ["-Osize", "-gnone"],
                    .when(platforms: [.wasi], configuration: .release)
                )
            ]
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
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi]))
            ],
            path: "Sources/App",
            exclude: ["NativeAppController.swift", "NativeMapView.swift"],
            swiftSettings: [
                .unsafeFlags(
                    ["-Osize", "-gnone"],
                    .when(platforms: [.wasi], configuration: .release)
                )
            ]
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
                .target(name: "DapperMapAppKit", condition: .when(platforms: [.macOS])),
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi]))
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
                        // instance grows it. The UI and worker share this memory while the
                        // datapack is decoded, so reserve enough for that peak and avoid grow.
                        "-Xlinker", "--initial-memory=268435456"
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
        .testTarget(
            name: "SDLInterfaceTests",
            dependencies: ["dappermap-sdl", "SDL2", "DapperMapCore", "DapperMapEngine"],
            path: "Tests/SDLInterfaceTests"
        ),
        .executableTarget(
            name: "benchstart",
            dependencies: [
                .product(name: "DPReader", package: "dpreader-swift")
            ],
            path: "Sources/benchstart"
        ),
    ]
)
