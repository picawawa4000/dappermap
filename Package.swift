// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "dappermap",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/picawawa4000/dpreader-swift.git", branch: "master"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", exact: "0.56.0")
    ],
    targets: [
        .executableTarget(
            name: "dappermap",
            dependencies: [
                .product(name: "DPReader", package: "dpreader-swift"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit")
            ],
            path: "Sources",
            exclude: [
                "benchstart"
            ],
            sources: [
                "main.swift"
            ],
            swiftSettings: [
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
            name: "benchstart",
            dependencies: [
                .product(name: "DPReader", package: "dpreader-swift")
            ],
            path: "Sources/benchstart"
        ),
    ]
)
