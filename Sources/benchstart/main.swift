import DPReader
import Foundation

private let bundlePath = URL(fileURLWithPath: "Web/default-datapack.bundle.json.gz")
private let runtimeRoot = URL(fileURLWithPath: "/private/tmp/dappermap-bench-default-datapack", isDirectory: true)
private let mapSize = 256
private let halfMapSize = Int32(mapSize / 2)
private let sampleY: Int32 = 256

private struct DatapackBundle: Decodable {
    let files: [DatapackBundleFile]
}

private struct DatapackBundleFile: Decodable {
    let path: String
    let contents: String?
    let base64Contents: String?
}

private func decompressGzip(at url: URL) throws -> Data {
    let process = Process()
    let standardOutput = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-dc", url.path]
    process.standardOutput = standardOutput
    try process.run()
    let data = try standardOutput.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return data
}

private struct StageTimer {
    private let clock = ContinuousClock()

    func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = clock.now
        let result = try body()
        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        print("\(label): \(String(format: "%.2f", ms)) ms")
        return result
    }

    func timeResult<T>(_ label: String, _ body: () throws -> T) -> Result<T, Error> {
        let start = clock.now
        do {
            let result = try body()
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            print("\(label): \(String(format: "%.2f", ms)) ms")
            return .success(result)
        } catch {
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
            print("\(label): failed after \(String(format: "%.2f", ms)) ms")
            print("\(label) error: \(error)")
            return .failure(error)
        }
    }
}

@main
enum BenchStart {
    static func main() throws {
        let timer = StageTimer()
        let fileManager = FileManager.default

        let bundleData = try timer.time("decompress bundle") {
            try decompressGzip(at: bundlePath)
        }

        let bundle = try timer.time("decode bundle json") {
            try JSONDecoder().decode(DatapackBundle.self, from: bundleData)
        }
        print("bundle files: \(bundle.files.count)")

        try? fileManager.removeItem(at: runtimeRoot)
        try timer.time("materialize bundle files") {
            try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true, attributes: nil)
            for file in bundle.files {
                let fileURL = runtimeRoot.appendingPathComponent(file.path)
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                let data: Data
                if let contents = file.contents {
                    data = Data(contents.utf8)
                } else if let base64Contents = file.base64Contents,
                          let decoded = Data(base64Encoded: base64Contents) {
                    data = decoded
                } else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try data.write(to: fileURL)
            }
        }

        let dataPack = try timer.time("DataPack init") {
            try DataPack(
                fromRootPath: runtimeRoot,
                loadingOptions: [
                    .noDimensions,
                    .noEnchantments,
                    .noStructures,
                    .noStructureSets,
                    .noStructureTemplates
                ],
                decodingVersion: .assumedCurrent
            )
        }

        guard case .success(let generator) = timer.timeResult("WorldGenerator init", {
            try WorldGenerator(
                withWorldSeed: 0,
                usingDataPacks: [dataPack],
                usingSettings: RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
            )
        }) else {
            return
        }

        let biomes = try timer.time("generate biome square") {
            try generator.generateBiomesInSquare(
                from: PosInt2D(x: -halfMapSize, z: -halfMapSize),
                to: PosInt2D(x: halfMapSize, z: halfMapSize),
                atY: sampleY,
                in: RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld"),
                scale: 1
            )
        }

        print("generated biomes: \(biomes?.count ?? 0)")

        try timer.time("set world seed") {
            try generator.setWorldSeed(12_345_678)
        }
        _ = try timer.time("generate biome square after reseed") {
            try generator.generateBiomesInSquare(
                from: PosInt2D(x: -halfMapSize, z: -halfMapSize),
                to: PosInt2D(x: halfMapSize, z: halfMapSize),
                atY: sampleY,
                in: RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld"),
                scale: 1
            )
        }
        _ = try timer.time("generate warm biome square") {
            try generator.generateBiomesInSquare(
                from: PosInt2D(x: -halfMapSize, z: -halfMapSize),
                to: PosInt2D(x: halfMapSize, z: halfMapSize),
                atY: sampleY,
                in: RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld"),
                scale: 1
            )
        }
    }
}
