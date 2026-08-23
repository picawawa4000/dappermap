import DPReader
import Foundation

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
#endif

#if canImport(wasi_pthread)
import wasi_pthread
import WASILibc
#endif

private let mapSize = 256
private let sampleY: Int32 = 256
private let defaultBundlePath = "./Web/default-datapack.bundle.json.gz"
private let runtimeDatapackPath = "./.dappermap/runtime/default-datapack"

private struct DatapackBundle: Decodable {
    let files: [DatapackBundleFile]
}

private struct DatapackBundleFile: Decodable {
    let path: String
    let contents: String?
    let base64Contents: String?
}

private enum BrowserAppError: Error {
    case message(String)
}

private func floorDivide(_ value: Int32, by divisor: Int32) -> Int32 {
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

private struct ViewState: Equatable, Sendable {
    let centerX: Double
    let centerZ: Double
    let blocksPerPixel: Double
    let viewportWidth: Int
    let viewportHeight: Int
}

private struct TileCacheKey: Hashable, Sendable {
    let seed: WorldSeed
    let scaleKey: Int
    let tileX: Int
    let tileZ: Int
}

/// A fused sampler has a fixed volume, so cache one for each tile shape and stride.
private struct TileSamplerKey: Hashable, Sendable {
    let sampleWidth: Int32
    let sampleScale: Int32
}

private struct BiomeColor: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    var cssHex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

}

private struct CachedTile: Sendable {
    let width: Int
    let height: Int
    let palette: [String]
    let biomeIndices: [UInt16]
}

private struct TileAtlas {
    let seed: WorldSeed
    let scaleKey: Int
    let minTileX: Int
    let maxTileX: Int
    let minTileZ: Int
    let maxTileZ: Int
}

private struct PendingTileJob: Sendable {
    let generation: Int
    let seed: WorldSeed
    let viewState: ViewState
    let tileBlocksPerPixel: Double
    let tileX: Int
    let tileZ: Int
}

private struct GeneratedTile: Sendable {
    let tile: CachedTile
    let generationMilliseconds: Double
}

private struct StructurePoint: Hashable, Sendable {
    let setID: String
    let structureID: String
    let x: Int32
    let z: Int32
}

private struct LootContainerPoint: Hashable, Sendable {
    let block: String
    let lootTable: String
    let x: Int32
    let y: Int32
    let z: Int32
    let loot: [String]
}

private struct StructureQuery: Sendable {
    let seed: WorldSeed
    let minX: Int32
    let maxX: Int32
    let minZ: Int32
    let maxZ: Int32
    let enabledStructureSets: Set<String>
    let minimumSpacingBlocks: Double
}

private enum StructurePlacementKind: String, Decodable, Sendable {
    case randomSpread = "minecraft:random_spread"
    case concentricRings = "minecraft:concentric_rings"
}

private struct StructureSetDescriptor: Sendable {
    let keyName: String
    let kind: StructurePlacementKind
    let spacing: Int32?
    let structureIDs: [String]
}

private struct EncodedStructureSet: Decodable {
    let placement: EncodedStructurePlacement
    let structures: [EncodedWeightedStructure]
}

private struct EncodedWeightedStructure: Decodable {
    let structure: String
}

private struct EncodedStructurePlacement: Decodable {
    let type: StructurePlacementKind
    let spacing: Int32?
}

private struct EncodedStructureDefinition: Decodable {
    let type: String
}

private enum TileSamplingBackend: Sendable {
    case nestedWASM
    case scalar
}

private struct TileProfilingMetrics {
    var generation = -1
    var sampledBiomeMilliseconds = 0.0
    var paletteMilliseconds = 0.0
    var rasterMilliseconds = 0.0
    var atlasMilliseconds = 0.0
    var viewportMilliseconds = 0.0
}

private struct TileDebugMetrics {
    var tileX: Int?
    var tileZ: Int?
    var blocksPerPixel: Double?
    var generationMilliseconds: Double?
    var renderMilliseconds: Double?
}

#if os(WASI)
private struct BiomeRowElements {
    let swatch: JSObject
    let colorInput: JSObject
}

private struct StructureRowElements {
    let swatch: JSObject
    let enabledInput: JSObject
    let colorInput: JSObject
}

private final class JSObjectSendableBox: @unchecked Sendable {
    let object: JSObject

    init(_ object: JSObject) {
        self.object = object
    }
}

/// Instantiates DPReader's nested modules in the browser's native WebAssembly engine.
private final class BrowserWASMRuntime: WASMRuntime, @unchecked Sendable {
    private var retainedImportClosures: [JSClosure] = []

    var supportsClimateFunctions: Bool { true }

    deinit {
        invalidate()
    }

    func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation {
        let bridge = makeDensityImports(imports)
        let exportFunction = try instantiate(
            module: module,
            exportName: exportName,
            imports: bridge.object
        )
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)

        return { x, y, z in
            exportBox.object(x, y, z).number ?? 0.0
        }
    }

    func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation {
        let bridge = makeDensityImports(imports)
        let exportFunction = try instantiate(
            module: module,
            exportName: exportName,
            imports: bridge.object
        )
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)

        return { x, y, z in
            let values = exportBox.object(x, y, z).object
            return WASMClimateSample(
                temperature: values?[0].number ?? 0.0,
                humidity: values?[1].number ?? 0.0,
                continentalness: values?[2].number ?? 0.0,
                erosion: values?[3].number ?? 0.0,
                weirdness: values?[4].number ?? 0.0,
                depth: values?[5].number ?? 0.0
            )
        }
    }

    func instantiateDensityFunctionBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionBulkInvocation {
        let bridge = makeDensityImports(imports)
        let exports = try instantiateExports(module: module, imports: bridge.object)
        guard
            let exportFunction = exports[exportName].object,
            let memory = exports[memoryExportName].object
        else {
            throw BrowserAppError.message("WASM bulk module is missing a required export.")
        }
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)
        let memoryBox = JSObjectSendableBox(memory)

        return { x, y, z, output in
            let byteOffset = Int(exportBox.object(x, y, z).number ?? 0.0)
            guard let buffer = memoryBox.object.buffer.object else { return }
            let values = JSObject.global.Float64Array.object!.new(
                buffer,
                byteOffset,
                sampleCount
            )
            // JavaScriptKit copies a typed array's entire backing buffer. Slice this view first so
            // the bridge copies only the bulk result rather than the module's whole linear memory.
            let copiedValues = JSTypedArray<Float64>(unsafelyWrapping: values.slice!().object!)
            copiedValues.copyMemory(to: UnsafeMutableBufferPointer(start: output, count: sampleCount))
        }
    }

    func instantiateBiomeIDBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMBiomeIDBulkInvocation {
        let bridge = makeDensityImports(imports)
        let exports = try instantiateExports(module: module, imports: bridge.object)
        guard
            let exportFunction = exports[exportName].object,
            let memory = exports[memoryExportName].object
        else {
            throw BrowserAppError.message("WASM biome bulk module is missing a required export.")
        }
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)
        let memoryBox = JSObjectSendableBox(memory)

        return { x, y, z, output in
            let byteOffset = Int(exportBox.object(x, y, z).number ?? 0.0)
            guard let buffer = memoryBox.object.buffer.object else { return }
            let values = JSObject.global.Int32Array.object!.new(
                buffer,
                byteOffset,
                sampleCount
            )
            // Slice before bridging so JavaScriptKit only copies the result volume.
            let copiedValues = JSTypedArray<Int32>(unsafelyWrapping: values.slice!().object!)
            copiedValues.copyMemory(to: UnsafeMutableBufferPointer(start: output, count: sampleCount))
        }
    }

    private func makeDensityImports(
        _ imports: WASMDensityFunctionImports
    ) -> (object: JSObject, closures: [JSClosure]) {
        let densityImport = JSClosure { arguments in
            guard arguments.count == 4 else { return 0.0.jsValue }
            return imports.sampleDensity(
                Int32(arguments[0].number ?? 0.0),
                Int32(arguments[1].number ?? 0.0),
                Int32(arguments[2].number ?? 0.0),
                Int32(arguments[3].number ?? 0.0)
            ).jsValue
        }
        let noiseImport = JSClosure { arguments in
            guard arguments.count == 4 else { return 0.0.jsValue }
            return imports.sampleNoise(
                Int32(arguments[0].number ?? 0.0),
                arguments[1].number ?? 0.0,
                arguments[2].number ?? 0.0,
                arguments[3].number ?? 0.0
            ).jsValue
        }

        let importsObject = JSObject()
        let dpreaderImports = JSObject()
        dpreaderImports["sample_density"] = densityImport.jsValue
        dpreaderImports["sample_noise"] = noiseImport.jsValue
        importsObject["dpreader"] = dpreaderImports.jsValue
        return (importsObject, [densityImport, noiseImport])
    }

    func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation {
        let exportFunction = try instantiate(
            module: module,
            exportName: exportName,
            imports: JSObject()
        )
        let exportBox = JSObjectSendableBox(exportFunction)

        return { temperature, humidity, continentalness, erosion, weirdness, depth, previousDistance, previousIndex in
            Int32(exportBox.object(
                temperature,
                humidity,
                continentalness,
                erosion,
                weirdness,
                depth,
                JSBigInt(_slowBridge: previousDistance),
                previousIndex
            ).number ?? -1.0)
        }
    }

    func invalidate() {
        retainedImportClosures.removeAll(keepingCapacity: false)
    }

    private func instantiate(
        module: [UInt8],
        exportName: String,
        imports: JSObject
    ) throws -> JSObject {
        let exports = try instantiateExports(module: module, imports: imports)
        guard let exportFunction = exports[exportName].object else {
            throw BrowserAppError.message("WASM module is missing its \(exportName) export.")
        }
        return exportFunction
    }

    private func instantiateExports(module: [UInt8], imports: JSObject) throws -> JSObject {
        let webAssembly = JSObject.global.WebAssembly.object!
        let moduleBytes = JSTypedArray<UInt8>(module)
        let compiledModule = try webAssembly.Module.object!.throws.new(moduleBytes)
        let instance = try webAssembly.Instance.object!.throws.new(compiledModule, imports)
        guard let exports = instance.exports.object else {
            throw BrowserAppError.message("WASM module did not expose exports.")
        }
        return exports
    }
}

#if canImport(wasi_pthread)
/// Swift Concurrency uses this lock while scheduling work. Spinning avoids blocking the browser's
/// main worker, which cannot use a blocking wait primitive.
@_cdecl("pthread_mutex_lock")
func dappermap_pthread_mutex_lock(_ mutex: UnsafeMutablePointer<pthread_mutex_t>) -> Int32 {
    var result: Int32
    repeat {
        result = pthread_mutex_trylock(mutex)
    } while result == EBUSY
    return result
}
#endif
#endif

private let vanillaBiomeDefaults: [String: BiomeColor] = [
    "minecraft:badlands": BiomeColor(red: 200, green: 120, blue: 60),
    "minecraft:bamboo_jungle": BiomeColor(red: 40, green: 170, blue: 70),
    "minecraft:basalt_deltas": BiomeColor(red: 60, green: 60, blue: 60),
    "minecraft:beach": BiomeColor(red: 230, green: 220, blue: 170),
    "minecraft:birch_forest": BiomeColor(red: 80, green: 170, blue: 80),
    "minecraft:cherry_grove": BiomeColor(red: 220, green: 160, blue: 180),
    "minecraft:cold_ocean": BiomeColor(red: 40, green: 80, blue: 180),
    "minecraft:crimson_forest": BiomeColor(red: 130, green: 20, blue: 20),
    "minecraft:dark_forest": BiomeColor(red: 20, green: 80, blue: 20),
    "minecraft:deep_cold_ocean": BiomeColor(red: 30, green: 70, blue: 150),
    "minecraft:deep_dark": BiomeColor(red: 20, green: 30, blue: 35),
    "minecraft:deep_frozen_ocean": BiomeColor(red: 90, green: 130, blue: 200),
    "minecraft:deep_lukewarm_ocean": BiomeColor(red: 50, green: 140, blue: 190),
    "minecraft:deep_ocean": BiomeColor(red: 20, green: 50, blue: 120),
    "minecraft:desert": BiomeColor(red: 235, green: 220, blue: 130),
    "minecraft:dripstone_caves": BiomeColor(red: 150, green: 120, blue: 90),
    "minecraft:end_barrens": BiomeColor(red: 170, green: 180, blue: 90),
    "minecraft:end_highlands": BiomeColor(red: 190, green: 200, blue: 110),
    "minecraft:end_midlands": BiomeColor(red: 180, green: 190, blue: 100),
    "minecraft:eroded_badlands": BiomeColor(red: 190, green: 110, blue: 55),
    "minecraft:flower_forest": BiomeColor(red: 60, green: 170, blue: 60),
    "minecraft:forest": BiomeColor(red: 34, green: 139, blue: 34),
    "minecraft:frozen_ocean": BiomeColor(red: 120, green: 170, blue: 230),
    "minecraft:frozen_peaks": BiomeColor(red: 210, green: 225, blue: 240),
    "minecraft:frozen_river": BiomeColor(red: 160, green: 200, blue: 255),
    "minecraft:grove": BiomeColor(red: 180, green: 220, blue: 180),
    "minecraft:ice_spikes": BiomeColor(red: 200, green: 230, blue: 255),
    "minecraft:jagged_peaks": BiomeColor(red: 200, green: 210, blue: 230),
    "minecraft:jungle": BiomeColor(red: 30, green: 150, blue: 50),
    "minecraft:lukewarm_ocean": BiomeColor(red: 60, green: 170, blue: 210),
    "minecraft:lush_caves": BiomeColor(red: 60, green: 150, blue: 80),
    "minecraft:mangrove_swamp": BiomeColor(red: 80, green: 100, blue: 50),
    "minecraft:meadow": BiomeColor(red: 90, green: 180, blue: 90),
    "minecraft:mushroom_fields": BiomeColor(red: 160, green: 80, blue: 160),
    "minecraft:nether_wastes": BiomeColor(red: 160, green: 60, blue: 40),
    "minecraft:ocean": BiomeColor(red: 30, green: 70, blue: 160),
    "minecraft:old_growth_birch_forest": BiomeColor(red: 60, green: 150, blue: 70),
    "minecraft:old_growth_pine_taiga": BiomeColor(red: 50, green: 110, blue: 90),
    "minecraft:old_growth_spruce_taiga": BiomeColor(red: 45, green: 100, blue: 85),
    "minecraft:pale_garden": BiomeColor(red: 140, green: 150, blue: 140),
    "minecraft:plains": BiomeColor(red: 120, green: 180, blue: 70),
    "minecraft:river": BiomeColor(red: 60, green: 110, blue: 200),
    "minecraft:savanna": BiomeColor(red: 180, green: 180, blue: 80),
    "minecraft:savanna_plateau": BiomeColor(red: 170, green: 170, blue: 70),
    "minecraft:small_end_islands": BiomeColor(red: 160, green: 170, blue: 85),
    "minecraft:snowy_beach": BiomeColor(red: 230, green: 240, blue: 250),
    "minecraft:snowy_plains": BiomeColor(red: 230, green: 240, blue: 250),
    "minecraft:snowy_slopes": BiomeColor(red: 220, green: 230, blue: 240),
    "minecraft:snowy_taiga": BiomeColor(red: 190, green: 210, blue: 220),
    "minecraft:soul_sand_valley": BiomeColor(red: 100, green: 80, blue: 60),
    "minecraft:sparse_jungle": BiomeColor(red: 50, green: 160, blue: 60),
    "minecraft:stony_peaks": BiomeColor(red: 130, green: 130, blue: 130),
    "minecraft:stony_shore": BiomeColor(red: 120, green: 120, blue: 120),
    "minecraft:sunflower_plains": BiomeColor(red: 130, green: 190, blue: 75),
    "minecraft:swamp": BiomeColor(red: 70, green: 90, blue: 50),
    "minecraft:taiga": BiomeColor(red: 60, green: 120, blue: 100),
    "minecraft:the_end": BiomeColor(red: 128, green: 128, blue: 255),
    "minecraft:the_void": BiomeColor(red: 0, green: 0, blue: 0),
    "minecraft:warm_ocean": BiomeColor(red: 70, green: 200, blue: 220),
    "minecraft:warped_forest": BiomeColor(red: 30, green: 130, blue: 120),
    "minecraft:windswept_forest": BiomeColor(red: 70, green: 130, blue: 90),
    "minecraft:windswept_gravelly_hills": BiomeColor(red: 110, green: 110, blue: 110),
    "minecraft:windswept_hills": BiomeColor(red: 120, green: 120, blue: 120),
    "minecraft:windswept_savanna": BiomeColor(red: 160, green: 160, blue: 70),
    "minecraft:wooded_badlands": BiomeColor(red: 210, green: 130, blue: 70),
]

private let vanillaStructureDefaults: [String: BiomeColor] = [
    "minecraft:ancient_city": BiomeColor(red: 69, green: 83, blue: 104),
    "minecraft:bastion_remnant": BiomeColor(red: 108, green: 67, blue: 52),
    "minecraft:buried_treasure": BiomeColor(red: 214, green: 177, blue: 74),
    "minecraft:desert_pyramid": BiomeColor(red: 222, green: 187, blue: 108),
    "minecraft:end_city": BiomeColor(red: 198, green: 130, blue: 210),
    "minecraft:fortress": BiomeColor(red: 163, green: 72, blue: 53),
    "minecraft:igloo": BiomeColor(red: 183, green: 225, blue: 238),
    "minecraft:jungle_pyramid": BiomeColor(red: 66, green: 132, blue: 73),
    "minecraft:mansion": BiomeColor(red: 76, green: 89, blue: 74),
    "minecraft:mineshaft": BiomeColor(red: 132, green: 93, blue: 56),
    "minecraft:mineshaft_mesa": BiomeColor(red: 181, green: 98, blue: 50),
    "minecraft:monument": BiomeColor(red: 68, green: 173, blue: 177),
    "minecraft:nether_fossil": BiomeColor(red: 151, green: 133, blue: 108),
    "minecraft:ocean_ruin_cold": BiomeColor(red: 105, green: 159, blue: 190),
    "minecraft:ocean_ruin_warm": BiomeColor(red: 198, green: 133, blue: 89),
    "minecraft:pillager_outpost": BiomeColor(red: 91, green: 76, blue: 61),
    "minecraft:ruined_portal": BiomeColor(red: 132, green: 68, blue: 143),
    "minecraft:shipwreck": BiomeColor(red: 125, green: 85, blue: 52),
    "minecraft:stronghold": BiomeColor(red: 130, green: 92, blue: 166),
    "minecraft:swamp_hut": BiomeColor(red: 87, green: 116, blue: 55),
    "minecraft:trail_ruins": BiomeColor(red: 174, green: 101, blue: 62),
    "minecraft:trial_chambers": BiomeColor(red: 86, green: 151, blue: 151),
    "minecraft:village_desert": BiomeColor(red: 229, green: 184, blue: 107),
    "minecraft:village_plains": BiomeColor(red: 198, green: 163, blue: 98),
    "minecraft:village_savanna": BiomeColor(red: 185, green: 137, blue: 65),
    "minecraft:village_snowy": BiomeColor(red: 202, green: 222, blue: 232),
    "minecraft:village_taiga": BiomeColor(red: 99, green: 133, blue: 102),
    "minecraft:woodland_mansion": BiomeColor(red: 65, green: 79, blue: 64)
]

@main
enum DapperMapMain {
#if os(WASI)
    @MainActor
    private static var app: AnyObject?
#endif

    static func main() {
#if os(WASI)
        JavaScriptEventLoop.installGlobalExecutor()
        Task {
            do {
                let tileExecutor = try await WebWorkerDedicatedExecutor()
                let structureExecutor = try await WebWorkerDedicatedExecutor()
                let samplingBackend = await MainActor.run {
                    webKitNeedsScalarTileSampling() ? TileSamplingBackend.scalar : .nestedWASM
                }
                let tileGenerator = TileGenerationService(
                    serialExecutor: .dedicated(tileExecutor),
                    samplingBackend: samplingBackend
                )
                let structureGenerator = TileGenerationService(
                    serialExecutor: .dedicated(structureExecutor),
                    // Loot generation can be computationally expensive, but does not need the
                    // nested browser-WASM sampler used for tiles. Keeping it scalar prevents a
                    // click-driven task from invoking JavaScript host functions off the worker.
                    samplingBackend: .scalar
                )
                await MainActor.run {
                    let browserApp = BrowserApp(
                        tileGenerator: tileGenerator,
                        structureGenerator: structureGenerator
                    )
                    app = browserApp
                    browserApp.start()
                }
            } catch {
                await MainActor.run {
                    let document = JSObject.global.document
                    document.getElementById("status").innerText =
                        "Failed to start tile generation worker: \(error)".jsValue
                    document.getElementById("status").className = "status error".jsValue
                }
            }
        }
#else
        print("This target is intended for the browser.")
        print("Build with the multithreaded WebAssembly Swift SDK, then package with `swift package --swift-sdk <sdk-id> js --use-cdn`.")
#endif
    }
}

#if os(WASI)
@MainActor
private func webKitNeedsScalarTileSampling() -> Bool {
    guard let userAgent = JSObject.global.navigator.userAgent.string else { return false }
    guard userAgent.contains("AppleWebKit") else { return false }
    return !userAgent.contains("Chrome/")
        && !userAgent.contains("Chromium/")
        && !userAgent.contains("Edg/")
}

private enum TileGenerationExecutor {
    case dedicated(WebWorkerDedicatedExecutor)

    var unownedExecutor: UnownedSerialExecutor {
        switch self {
        case .dedicated(let executor):
            return executor.asUnownedSerialExecutor()
        }
    }
}

/// Keeps DPReader sampling, including the nested WASM fast path, on one dedicated worker thread.
private actor TileGenerationService {
    // A custom actor executor must be available without actor isolation. Leaving this stored
    // property isolated can cause a synchronous actor entry (such as `loot`) to trip Swift's
    // executor precondition after an async hop from a JavaScript event callback.
    private nonisolated let serialExecutor: TileGenerationExecutor
    private let samplingBackend: TileSamplingBackend
    private let overworldDimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private let overworldNoiseSettings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    private let tileSize = 256
    private var dataPack: DataPack?
    private var currentSeed: WorldSeed?
    private var generator: WorldGenerator?
    private var wasmRuntime: BrowserWASMRuntime?
    private var samplers: [TileSamplerKey: CompiledNoiseRouterBiomeBulkSampler] = [:]
    private var structureSampler: StructurePlacementSampler?
    private var structureSetDescriptors: [StructureSetDescriptor] = []
    private var dataPackRoot: URL?
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        serialExecutor.unownedExecutor
    }

    init(serialExecutor: TileGenerationExecutor, samplingBackend: TileSamplingBackend) {
        self.serialExecutor = serialExecutor
        self.samplingBackend = samplingBackend
    }

    nonisolated func scheduleLoot(
        for structure: StructurePoint,
        seed: WorldSeed
    ) -> Task<[LootContainerPoint], Error> {
        switch serialExecutor {
        case .dedicated(let executor):
            return Task(executorPreference: executor) {
                try await self.loot(for: structure, seed: seed)
            }
        }
    }

    func initialize(bundleText: String) throws {
        let bundle = try JSONDecoder().decode(DatapackBundle.self, from: Data(bundleText.utf8))
        let rootURL = try materialize(bundle: bundle)
        dataPackRoot = rootURL
        dataPack = try DataPack(
            fromRootPath: rootURL,
            loadingOptions: [
                .noDimensions
            ],
            decodingVersion: .assumedCurrent
        )
        structureSetDescriptors = try dataPack!.structureSetRegistry.entries().compactMap { entry in
            let data = try JSONEncoder().encode(entry.value)
            let encoded = try JSONDecoder().decode(EncodedStructureSet.self, from: data)
            return StructureSetDescriptor(
                keyName: entry.key.name,
                kind: encoded.placement.type,
                spacing: encoded.placement.spacing,
                structureIDs: encoded.structures.map(\.structure)
            )
        }
    }

    func generate(_ job: PendingTileJob) throws -> GeneratedTile {
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }

        try configureGenerator(for: job.seed, using: dataPack)

        let start = Date()
        let tile = try makeTile(
            using: generator!,
            blocksPerPixel: job.tileBlocksPerPixel,
            tileX: job.tileX,
            tileZ: job.tileZ
        )
        return GeneratedTile(
            tile: tile,
            generationMilliseconds: Date().timeIntervalSince(start) * 1_000.0
        )
    }

    func structures(in query: StructureQuery) throws -> [StructurePoint] {
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }
        try configureGenerator(for: query.seed, using: dataPack)
        guard let generator, let structureSampler else { return [] }

        var points = Set<StructurePoint>()
        for descriptor in structureSetDescriptors where query.enabledStructureSets.contains(descriptor.keyName) {
            let samples: [StructurePlacementSample]
            switch descriptor.kind {
            case .randomSpread:
                guard let spacing = descriptor.spacing, spacing > 0 else { continue }
                guard Double(spacing) * 16.0 >= query.minimumSpacingBlocks else { continue }
                var minRegionX = floorDivide(query.minX, by: spacing * 16) - 1
                var maxRegionX = floorDivide(query.maxX, by: spacing * 16) + 1
                var minRegionZ = floorDivide(query.minZ, by: spacing * 16) - 1
                var maxRegionZ = floorDivide(query.maxZ, by: spacing * 16) + 1
                let regionCount = Int64(maxRegionX - minRegionX + 1) * Int64(maxRegionZ - minRegionZ + 1)
                // At far zoom levels, one-per-chunk sets (such as mineshafts) would produce
                // millions of candidates. Sample a centered 32×32 region window instead.
                if regionCount > 1_024 {
                    let centerX = Int32((Int64(query.minX) + Int64(query.maxX)) / 2)
                    let centerZ = Int32((Int64(query.minZ) + Int64(query.maxZ)) / 2)
                    let centerRegionX = floorDivide(centerX, by: spacing * 16)
                    let centerRegionZ = floorDivide(centerZ, by: spacing * 16)
                    minRegionX = centerRegionX - 16
                    maxRegionX = centerRegionX + 15
                    minRegionZ = centerRegionZ - 16
                    maxRegionZ = centerRegionZ + 15
                }
                var generated: [StructurePlacementSample] = []
                for regionZ in minRegionZ...maxRegionZ {
                    for regionX in minRegionX...maxRegionX {
                        if let sample = try structureSampler.sampleStructureSet(
                            inRegion: PosInt2D(x: regionX, z: regionZ),
                            for: RegistryKey(referencing: descriptor.keyName)
                        ) {
                            generated.append(sample)
                        }
                    }
                }
                samples = generated
            case .concentricRings:
                continue
            }

            for sample in samples where pointIsVisible(sample.blockPos, in: query) {
                let biome = try generator.sampleBiome(
                    at: PosInt3D(
                        x: sample.chunkPos.x &* 16 &+ 8,
                        y: 256,
                        z: sample.chunkPos.z &* 16 &+ 8
                    ),
                    in: overworldDimension
                )
                guard let biome, let structure = try structureSampler.resolveStructure(for: sample, biome: biome) else {
                    continue
                }
                points.insert(StructurePoint(
                    setID: descriptor.keyName,
                    structureID: structure.name,
                    x: sample.blockPos.x,
                    z: sample.blockPos.z
                ))
            }
        }
        return points.sorted { ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID) }
    }

    /// Ring placements are deliberately a second pass: DPReader enumerates all rings before it
    /// returns any stronghold, which should not hold up the normal map and random-spread overlay.
    func concentricStructures(in query: StructureQuery) throws -> [StructurePoint] {
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }
        try configureGenerator(for: query.seed, using: dataPack)
        guard let generator, let structureSampler else { return [] }

        var points = Set<StructurePoint>()
        for descriptor in structureSetDescriptors
        where descriptor.kind == .concentricRings && query.enabledStructureSets.contains(descriptor.keyName) {
            let samples = try structureSampler.sampleAllPlacements(
                for: RegistryKey(referencing: descriptor.keyName)
            )
            for sample in samples where pointIsVisible(sample.blockPos, in: query) {
                let biome = try generator.sampleBiome(
                    at: PosInt3D(
                        x: sample.chunkPos.x &* 16 &+ 8,
                        y: 256,
                        z: sample.chunkPos.z &* 16 &+ 8
                    ),
                    in: overworldDimension
                )
                guard let biome, let structure = try structureSampler.resolveStructure(for: sample, biome: biome) else {
                    continue
                }
                points.insert(StructurePoint(
                    setID: descriptor.keyName,
                    structureID: structure.name,
                    x: sample.blockPos.x,
                    z: sample.blockPos.z
                ))
            }
        }
        return points.sorted { ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID) }
    }

    func loot(for structure: StructurePoint, seed: WorldSeed) throws -> [LootContainerPoint] {
        guard let dataPack, let rootURL = dataPackRoot else {
            throw BrowserAppError.message("Structure generation worker is not ready.")
        }
        guard let definition = dataPack.structureRegistry.get(RegistryKey(referencing: structure.structureID)) else {
            return []
        }
        let encodedDefinition = try JSONDecoder().decode(
            EncodedStructureDefinition.self,
            from: JSONEncoder().encode(definition)
        )
        let startChunk = PosInt2D(x: floorDivide(structure.x, by: 16), z: floorDivide(structure.z, by: 16))
        var terrainChunks: [String: ProtoChunk] = [:]
        var terrainChunkCoordinates = Set<String>()
        switch encodedDefinition.type {
        case "minecraft:desert_pyramid":
            // Desert pyramids determine their final Y position from the terrain beneath their
            // 21×21 footprint. The default context is all air, which rejects every pyramid.
            for chunkZ in startChunk.z...(startChunk.z + 1) {
                for chunkX in startChunk.x...(startChunk.x + 1) {
                    terrainChunkCoordinates.insert("\(chunkX),\(chunkZ)")
                }
            }
        default:
            break
        }

        if !terrainChunkCoordinates.isEmpty {
            try configureGenerator(for: seed, using: dataPack)
            guard let generator else {
                throw BrowserAppError.message("Structure generation worker is not ready.")
            }
            for coordinate in terrainChunkCoordinates {
                let values = coordinate.split(separator: ",", maxSplits: 1).compactMap { Int32($0) }
                guard values.count == 2 else { continue }
                let chunk = ProtoChunk()
                try generator.generateInto(chunk, at: PosInt2D(x: values[0], z: values[1]))
                terrainChunks[coordinate] = chunk
            }
        }

        let air = BlockState(type: Block(withID: "minecraft:air"))
        let terrain = BlockState(type: Block(withID: "minecraft:stone"))
        let context = StructureGenerationContext(
            seaLevel: 63,
            minimumWorldY: -64,
            usingDataPacks: [dataPack],
            blockSampler: { position in
                let chunkX = floorDivide(position.x, by: 16)
                let chunkZ = floorDivide(position.z, by: 16)
                guard let chunk = terrainChunks["\(chunkX),\(chunkZ)"],
                      position.y >= chunk.minY,
                      position.y < chunk.minY + chunk.height else {
                    return air
                }
                let localPosition = PosInt3D(
                    x: position.x - chunkX * 16,
                    y: position.y - chunk.minY,
                    z: position.z - chunkZ * 16
                )
                return chunk.isTerrain(atLocal: localPosition) ? terrain : air
            }
        )
        // The map intentionally shows biome-valid placement candidates. Mansion layouts need a
        // terrain height only for their vertical anchor, but our coarse density preview can
        // disagree with vanilla's final surface at a corner. Use the vanilla flat-reference
        // anchor so candidate loot remains deterministic and matches DPReader's layout.
        let lootContext: StructureGenerationContext
        if encodedDefinition.type == "minecraft:woodland_mansion" {
            let mansionTerrain = BlockState(type: Block(withID: "minecraft:stone"))
            lootContext = StructureGenerationContext(
                seaLevel: 63,
                minimumWorldY: -64,
                usingDataPacks: [dataPack],
                blockSampler: { position in position.y <= 70 ? mansionTerrain : air }
            )
        } else if encodedDefinition.type == "minecraft:stronghold" {
            // Stronghold post-processing consumes its decoration RNG only while replacing
            // terrain. Match DPReader's validated flat-stone generation context.
            lootContext = StructureGenerationContext(
                seaLevel: 63,
                minimumWorldY: -64,
                usingDataPacks: [dataPack],
                blockSampler: { position in position.y <= 63 ? terrain : air }
            )
        } else {
            lootContext = context
        }
        let generatedContainers = try definition.generateLoot(
            worldSeed: seed,
            startChunk: startChunk,
            context: lootContext
        )
        guard let containers = generatedContainers else {
            return []
        }
        var resolvedContainers: [LootContainerPoint] = []
        resolvedContainers.reserveCapacity(containers.count)
        for container in containers {
            let items = (try? lootItems(
                for: container.lootTable,
                seed: container.lootSeed,
                rootURL: rootURL,
                enchantmentResources: dataPack.lootEnchantmentResources
            )) ?? []
            resolvedContainers.append(LootContainerPoint(
                block: container.block,
                lootTable: container.lootTable,
                x: container.pos.x,
                y: container.pos.y,
                z: container.pos.z,
                loot: items
            ))
        }
        return resolvedContainers
    }

    nonisolated private func lootItems(
        for tableID: String,
        seed: Int64,
        rootURL: URL,
        enchantmentResources: LootEnchantmentResources
    ) throws -> [String] {
        let parts = tableID.split(separator: ":", maxSplits: 1)
        let namespace = parts.count == 2 ? String(parts[0]) : "minecraft"
        let path = parts.count == 2 ? String(parts[1]) : tableID
        let tableURL = rootURL.appendingPathComponent("data/\(namespace)/loot_table/\(path).json")
        let table = try JSONDecoder().decode(LootTable.self, from: Data(contentsOf: tableURL))
        let items = try table.generateLoot(withContext: LootContext(
            random: CheckedRandom(seed: UInt64(bitPattern: seed)),
            enchantmentResources: enchantmentResources
        ))
        var itemOrder: [String] = []
        var itemCounts: [String: Int] = [:]
        for item in items {
            let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: item).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            })
            let name = fields["itemName"] ?? "unknown"
            let count = Int(fields["count"] ?? "") ?? 0
            if itemCounts[name] == nil {
                itemOrder.append(name)
            }
            itemCounts[name, default: 0] += count
        }
        return itemOrder.map { "\(itemCounts[$0, default: 0]) × \($0)" }
    }

    private func configureGenerator(for seed: WorldSeed, using dataPack: DataPack) throws {
        if currentSeed != seed || generator == nil {
            switch samplingBackend {
            case .nestedWASM:
                let runtime = BrowserWASMRuntime()
                do {
                    generator = try WorldGenerator(
                        withWorldSeed: seed,
                        usingDataPacks: [dataPack],
                        usingSettings: overworldNoiseSettings,
                        compilationBackend: .wasm,
                        wasmRuntime: runtime
                    )
                } catch {
                    runtime.invalidate()
                    throw error
                }
                wasmRuntime?.invalidate()
                wasmRuntime = runtime
            case .scalar:
                generator = try WorldGenerator(
                    withWorldSeed: seed,
                    usingDataPacks: [dataPack],
                    usingSettings: overworldNoiseSettings
                )
                wasmRuntime?.invalidate()
                wasmRuntime = nil
            }
            currentSeed = seed
            samplers.removeAll(keepingCapacity: true)
            structureSampler = StructurePlacementSampler(withWorldSeed: seed, usingDataPacks: [dataPack])
        }
    }

    private func pointIsVisible(_ point: PosInt2D, in query: StructureQuery) -> Bool {
        point.x >= query.minX && point.x <= query.maxX
            && point.z >= query.minZ && point.z <= query.maxZ
    }

    private func makeTile(
        using generator: WorldGenerator,
        blocksPerPixel: Double,
        tileX: Int,
        tileZ: Int
    ) throws -> CachedTile {
        let pixelsPerSample = max(1, Int((1.0 / blocksPerPixel).rounded()))
        let sampleScale = max(1, Int32(blocksPerPixel.rounded()))
        let sampleWidth = tileSize / pixelsPerSample
        let startX = Int32((Double(tileX * tileSize) * blocksPerPixel).rounded())
        let startZ = Int32((Double(tileZ * tileSize) * blocksPerPixel).rounded())
        let biomeIDs: [String]
        switch samplingBackend {
        case .nestedWASM:
            let key = TileSamplerKey(sampleWidth: Int32(sampleWidth), sampleScale: sampleScale)
            let sampler: CompiledNoiseRouterBiomeBulkSampler
            if let existing = samplers[key] {
                sampler = existing
            } else {
                sampler = try generator.makeBiomeIDBulkSampler(
                    for: CompiledDensityFunctionBufferContext(
                        xCount: Int32(sampleWidth), yCount: 1, zCount: Int32(sampleWidth),
                        xStep: sampleScale, yStep: 1, zStep: sampleScale
                    ),
                    in: overworldDimension,
                    strategy: .wasm
                )
                samplers[key] = sampler
            }
            let volume = sampler(at: PosInt3D(x: startX, y: sampleY, z: startZ))
            biomeIDs = volume.biomeIDs.map { volume.palette[Int($0)].name }
        case .scalar:
            let extent = Int32(sampleWidth) * sampleScale
            guard let biomes = try generator.generateBiomesInSquare(
                from: PosInt2D(x: startX, z: startZ),
                to: PosInt2D(x: startX + extent, z: startZ + extent),
                atY: sampleY,
                in: overworldDimension,
                scale: sampleScale,
                forceNoBaking: true
            ) else {
                throw BrowserAppError.message("The overworld biome sampler returned no data.")
            }
            biomeIDs = biomes.map(\.name)
        }

        var palette = ["minecraft:plains"]
        var paletteIndices = ["minecraft:plains": UInt16(0)]
        var indices = [UInt16](repeating: 0, count: biomeIDs.count)
        for (index, biomeID) in biomeIDs.enumerated() {
            let paletteIndex = paletteIndices[biomeID] ?? UInt16(palette.count)
            if paletteIndices[biomeID] == nil {
                guard palette.count <= Int(UInt16.max) else {
                    throw BrowserAppError.message("A tile contains too many biome types.")
                }
                palette.append(biomeID)
                paletteIndices[biomeID] = paletteIndex
            }
            indices[index] = paletteIndex
        }
        return CachedTile(width: sampleWidth, height: sampleWidth, palette: palette, biomeIndices: indices)
    }

    private func materialize(bundle: DatapackBundle) throws -> URL {
        let rootURL = URL(fileURLWithPath: runtimeDatapackPath, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        for file in bundle.files {
            let url = rootURL.appendingPathComponent(file.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let contents: Data
            if let base64Contents = file.base64Contents {
                guard let decoded = Data(base64Encoded: base64Contents) else {
                    throw BrowserAppError.message("Datapack bundle contains invalid base64 data for \(file.path).")
                }
                contents = decoded
            } else if let text = file.contents {
                contents = Data(text.utf8)
            } else {
                throw BrowserAppError.message("Datapack bundle is missing contents for \(file.path).")
            }
            try contents.write(to: url)
        }
        return rootURL
    }

}

@MainActor
private final class BrowserApp {
    private let document: JSObject
    private let viewport: JSObject
    private let seedInput: JSObject
    private let renderButton: JSObject
    private let statusElement: JSObject
    private let biomeResetButton: JSObject
    private let biomeImportButton: JSObject
    private let biomeExportButton: JSObject
    private let biomeExportCubiomesButton: JSObject
    private let biomeImportInput: JSObject
    private let biomeSummaryElement: JSObject
    private let biomeEmptyElement: JSObject
    private let biomeListElement: JSObject
    private let structureResetButton: JSObject
    private let structureSummaryElement: JSObject
    private let structureEmptyElement: JSObject
    private let structureListElement: JSObject
    private let lootInfoElement: JSObject
    private let lootMessageElement: JSObject
    private let lootListElement: JSObject
    private let debugLastTileElement: JSObject
    private let debugGenerationTimeElement: JSObject
    private let debugRenderTimeElement: JSObject
    private let debugPendingTilesElement: JSObject
    private let debugCachedTilesElement: JSObject
    private let tooltipElement: JSObject
    private let canvas: JSObject
    private let context: JSObject
    private let overlayCanvas: JSObject
    private let overlayContext: JSObject
    private let snapshotCanvas: JSObject
    private let snapshotContext: JSObject
    private let fallbackCanvas: JSObject
    private let fallbackContext: JSObject

    private var retainedClosures: [JSClosure] = []
    private var pendingTimer: JSTimer?
    private var dataPack: DataPack?
    private var currentSeed: WorldSeed?
    private let tileGenerator: TileGenerationService
    private let structureGenerator: TileGenerationService
    private var inFlightTileJob: PendingTileJob?
    private var inFlightTileTask: Task<Void, Never>?
    private var pendingRenderTimer: JSTimer?
    private var pendingTileTimer: JSTimer?
    private var latestViewState: ViewState?
    private var tileCache: [TileCacheKey: CachedTile] = [:]
    private var tileRasterCache: [TileCacheKey: JSObject] = [:]
    private var tileCanvasCache: [TileCacheKey: JSObject] = [:]
    private var tileAtlas: TileAtlas?
    private var fallbackTileAtlas: TileAtlas?
    private var pendingTileJobs: [PendingTileJob] = []
    private var activeViewGeneration = 0
    private var profilingEnabled = false
    private var profilingMetrics = TileProfilingMetrics()
    private var tileDebugMetrics = TileDebugMetrics()
    private var biomeColors: [String: BiomeColor] = [:]
    private var biomeColorCache: [String: String] = [:]
    private var biomeRowElements: [String: BiomeRowElements] = [:]
    private var loadedBiomeIDs: [String] = []
    private var structureColors: [String: BiomeColor] = [:]
    private var enabledStructureSets: [String: Bool] = [:]
    private var structureSetSpacings: [String: Int32] = [:]
    private var structureRowElements: [String: StructureRowElements] = [:]
    private var loadedStructureIDs: [String] = []
    private var visibleStructurePoints: [StructurePoint] = []
    private var visibleLootContainers: [LootContainerPoint] = []
    private var activeLootStructure: StructurePoint?
    private var activeLootRequest = 0
    private var lootContainerDetails: [LootContainerPoint: JSObject] = [:]
    private var inFlightLootTask: Task<Void, Never>?
    private var inFlightStructureTask: Task<Void, Never>?
    private var inFlightConcentricStructureTask: Task<Void, Never>?
    private var requestedStructureGeneration: Int?
    private var viewCenterX = 0.0
    private var viewCenterZ = 0.0
    private var viewBlocksPerPixel = 1.0
    private var viewportWidth = mapSize
    private var viewportHeight = mapSize
    private var dragPointerID: Double?
    private var dragStartClientX = 0.0
    private var dragStartClientY = 0.0
    private var dragOriginCenterX = 0.0
    private var dragOriginCenterZ = 0.0
    private var dragDidMove = false

    private let overworldDimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private let overworldNoiseSettings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    private let tileSize = 256
    private let placeholderColor = "#ece6d3"
    private let gridLineColor = "rgba(29, 41, 29, 0.18)"
    private let gridLabelColor = "rgba(29, 41, 29, 0.72)"

    init(tileGenerator: TileGenerationService, structureGenerator: TileGenerationService) {
        self.tileGenerator = tileGenerator
        self.structureGenerator = structureGenerator
        self.document = JSObject.global.document.object!
        self.viewport = document.getElementById!("map-viewport").object!
        self.seedInput = document.getElementById!("seed-input").object!
        self.renderButton = document.getElementById!("render-button").object!
        self.statusElement = document.getElementById!("status").object!
        self.biomeResetButton = document.getElementById!("biome-reset-button").object!
        self.biomeImportButton = document.getElementById!("biome-import-button").object!
        self.biomeExportButton = document.getElementById!("biome-export-button").object!
        self.biomeExportCubiomesButton = document.getElementById!("biome-export-cubiomes-button").object!
        self.biomeImportInput = document.getElementById!("biome-import-input").object!
        self.biomeSummaryElement = document.getElementById!("biome-summary").object!
        self.biomeEmptyElement = document.getElementById!("biome-empty").object!
        self.biomeListElement = document.getElementById!("biome-list").object!
        self.structureResetButton = document.getElementById!("structure-reset-button").object!
        self.structureSummaryElement = document.getElementById!("structure-summary").object!
        self.structureEmptyElement = document.getElementById!("structure-empty").object!
        self.structureListElement = document.getElementById!("structure-list").object!
        self.lootInfoElement = document.getElementById!("loot-info").object!
        self.lootMessageElement = document.getElementById!("loot-message").object!
        self.lootListElement = document.getElementById!("loot-list").object!
        self.debugLastTileElement = document.getElementById!("debug-last-tile").object!
        self.debugGenerationTimeElement = document.getElementById!("debug-generation-time").object!
        self.debugRenderTimeElement = document.getElementById!("debug-render-time").object!
        self.debugPendingTilesElement = document.getElementById!("debug-pending-tiles").object!
        self.debugCachedTilesElement = document.getElementById!("debug-cached-tiles").object!
        self.tooltipElement = document.getElementById!("map-tooltip").object!
        self.canvas = document.getElementById!("map-canvas").object!
        self.context = canvas.getContext!("2d").object!
        self.overlayCanvas = document.getElementById!("map-overlay").object!
        self.overlayContext = overlayCanvas.getContext!("2d").object!
        self.snapshotCanvas = document.createElement!("canvas").object!
        self.snapshotContext = snapshotCanvas.getContext!("2d").object!
        self.fallbackCanvas = document.createElement!("canvas").object!
        self.fallbackContext = fallbackCanvas.getContext!("2d").object!
    }

    func start() {
        profilingEnabled = false
        if profilingEnabled {
            viewCenterX = JSObject.global["__dappermapProfileCenterX"].number ?? viewCenterX
            viewCenterZ = JSObject.global["__dappermapProfileCenterZ"].number ?? viewCenterZ
            viewBlocksPerPixel = JSObject.global["__dappermapProfileBlocksPerPixel"].number ?? viewBlocksPerPixel
        }
        updateDebugPanel()
        canvas.width = mapSize.jsValue
        canvas.height = mapSize.jsValue
        overlayCanvas.width = mapSize.jsValue
        overlayCanvas.height = mapSize.jsValue
        snapshotCanvas.width = mapSize.jsValue
        snapshotCanvas.height = mapSize.jsValue
        fallbackCanvas.width = mapSize.jsValue
        fallbackCanvas.height = mapSize.jsValue
        configureCanvasContext(context)
        configureCanvasContext(overlayContext)
        configureCanvasContext(snapshotContext)
        configureCanvasContext(fallbackContext)
        syncViewportSize()
        attachHandlers()
        renderLootPanel(message: nil)
        setLoading(true)
        setStatus("Loading Minecraft 1.21.11 datapack…")
        scheduleNextTick { [weak self] in
            self?.loadDefaultDatapack()
        }
    }

    private func handleGeneratedTile(_ result: GeneratedTile, for job: PendingTileJob) {
        inFlightTileJob = nil
        inFlightTileTask = nil
        guard
            job.generation == activeViewGeneration,
            let seed = currentSeed,
            seed == job.seed
        else {
            scheduleNextTileBatch()
            return
        }

        let key = TileCacheKey(seed: seed, scaleKey: scaleKey(for: job.tileBlocksPerPixel), tileX: job.tileX, tileZ: job.tileZ)
        tileCache[key] = result.tile
        tileDebugMetrics.tileX = job.tileX
        tileDebugMetrics.tileZ = job.tileZ
        tileDebugMetrics.blocksPerPixel = job.tileBlocksPerPixel
        tileDebugMetrics.generationMilliseconds = result.generationMilliseconds

        let renderStart = Date()
        redrawTileIfCurrent(job: job)
        tileDebugMetrics.renderMilliseconds = Date().timeIntervalSince(renderStart) * 1_000.0
        updateDebugPanel()

        guard let viewState = latestViewState else { return }
        if pendingTileJobs.isEmpty {
            setStatus("Rendered seed \(displaySeed(seed)) at Y=256, centered on (\(Int(viewState.centerX.rounded())), \(Int(viewState.centerZ.rounded()))) with \(String(format: "%.2f", viewState.blocksPerPixel)) block(s) per pixel.")
        } else {
            scheduleNextTileBatch()
        }
    }

    private func handleTileGenerationFailure(_ error: Error, for job: PendingTileJob) {
        inFlightTileJob = nil
        inFlightTileTask = nil
        if job.generation != activeViewGeneration || job.seed != currentSeed {
            scheduleNextTileBatch()
            return
        }
        pendingTileJobs.removeAll(keepingCapacity: true)
        updateDebugPanel()
        setStatus("Render failed: \(error)", isError: true)
    }

    private func attachHandlers() {
        let clickClosure = JSClosure { [weak self] _ in
            self?.prepareRender()
            return .undefined
        }
        retainedClosures.append(clickClosure)
        _ = renderButton.addEventListener!("click", clickClosure)

        let keyClosure = JSClosure { [weak self] args in
            guard let event = args.first?.object else { return .undefined }
            guard event.key.string == "Enter" else { return .undefined }
            _ = event.preventDefault!()
            self?.prepareRender()
            return .undefined
        }
        retainedClosures.append(keyClosure)
        _ = seedInput.addEventListener!("keydown", keyClosure)

        let biomeResetClosure = JSClosure { [weak self] _ in
            self?.resetBiomeColorsToDefaults()
            return .undefined
        }
        retainedClosures.append(biomeResetClosure)
        _ = biomeResetButton.addEventListener!("click", biomeResetClosure)

        let structureResetClosure = JSClosure { [weak self] _ in
            self?.resetStructureColorsToDefaults()
            return .undefined
        }
        retainedClosures.append(structureResetClosure)
        _ = structureResetButton.addEventListener!("click", structureResetClosure)

        let biomeImportButtonClosure = JSClosure { [weak self] _ in
            self?.biomeImportInput.value = "".jsValue
            _ = self?.biomeImportInput.click?()
            return .undefined
        }
        retainedClosures.append(biomeImportButtonClosure)
        _ = biomeImportButton.addEventListener!("click", biomeImportButtonClosure)

        let biomeImportChangeClosure = JSClosure { [weak self] _ in
            self?.handleBiomeImportSelection()
            return .undefined
        }
        retainedClosures.append(biomeImportChangeClosure)
        _ = biomeImportInput.addEventListener!("change", biomeImportChangeClosure)

        let biomeExportClosure = JSClosure { [weak self] _ in
            self?.exportBiomeColors(usingCubiomesFormat: false)
            return .undefined
        }
        retainedClosures.append(biomeExportClosure)
        _ = biomeExportButton.addEventListener!("click", biomeExportClosure)

        let biomeExportCubiomesClosure = JSClosure { [weak self] _ in
            self?.exportBiomeColors(usingCubiomesFormat: true)
            return .undefined
        }
        retainedClosures.append(biomeExportCubiomesClosure)
        _ = biomeExportCubiomesButton.addEventListener!("click", biomeExportCubiomesClosure)

        let wheelClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            _ = event.preventDefault!()
            self.syncViewportSize()
            let factor = exp((event.deltaY.number ?? 0.0) * 0.0015)
            self.zoom(
                atClientX: event.clientX.number ?? 0.0,
                clientY: event.clientY.number ?? 0.0,
                factor: factor
            )
            return .undefined
        }
        retainedClosures.append(wheelClosure)
        _ = viewport.addEventListener!("wheel", wheelClosure)

        let pointerDownClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            _ = event.preventDefault!()
            self.syncViewportSize()
            self.dragPointerID = event.pointerId.number
            self.dragStartClientX = event.clientX.number ?? 0.0
            self.dragStartClientY = event.clientY.number ?? 0.0
            self.dragOriginCenterX = self.viewCenterX
            self.dragOriginCenterZ = self.viewCenterZ
            self.dragDidMove = false
            self.setDragging(true)
            _ = self.viewport.setPointerCapture?(event.pointerId)
            return .undefined
        }
        retainedClosures.append(pointerDownClosure)
        _ = viewport.addEventListener!("pointerdown", pointerDownClosure)

        let pointerMoveClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            self.updateTooltip(forClientX: event.clientX.number ?? 0.0, clientY: event.clientY.number ?? 0.0)
            guard self.dragPointerID == event.pointerId.number else { return .undefined }

            let dx = (event.clientX.number ?? 0.0) - self.dragStartClientX
            let dy = (event.clientY.number ?? 0.0) - self.dragStartClientY
            if abs(dx) > 3.0 || abs(dy) > 3.0 { self.dragDidMove = true }
            self.viewCenterX = self.dragOriginCenterX - dx * self.viewBlocksPerPixel
            self.viewCenterZ = self.dragOriginCenterZ - dy * self.viewBlocksPerPixel
            self.previewCurrentViewIfPossible()
            self.scheduleVisibleRegionRender()
            return .undefined
        }
        retainedClosures.append(pointerMoveClosure)
        _ = viewport.addEventListener!("pointermove", pointerMoveClosure)

        let pointerEndClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            guard self.dragPointerID == event.pointerId.number else { return .undefined }

            self.dragPointerID = nil
            self.setDragging(false)
            _ = self.viewport.releasePointerCapture?(event.pointerId)
            self.scheduleVisibleRegionRender()
            return .undefined
        }
        retainedClosures.append(pointerEndClosure)
        _ = viewport.addEventListener!("pointerup", pointerEndClosure)
        _ = viewport.addEventListener!("pointercancel", pointerEndClosure)

        // Use the browser's completed click gesture for selection. `pointerup` is also used for
        // drag cleanup and can be suppressed by pointer capture on some browsers.
        let mapClickClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            self.selectMapItem(atClientX: event.clientX.number ?? 0.0, clientY: event.clientY.number ?? 0.0)
            return .undefined
        }
        retainedClosures.append(mapClickClosure)
        _ = viewport.addEventListener!("click", mapClickClosure)

        let pointerLeaveClosure = JSClosure { [weak self] _ in
            self?.hideTooltip()
            return .undefined
        }
        retainedClosures.append(pointerLeaveClosure)
        _ = viewport.addEventListener!("pointerleave", pointerLeaveClosure)

        let doubleClickClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            _ = event.preventDefault!()
            self.syncViewportSize()
            self.zoom(
                atClientX: event.clientX.number ?? 0.0,
                clientY: event.clientY.number ?? 0.0,
                factor: 0.5
            )
            return .undefined
        }
        retainedClosures.append(doubleClickClosure)
        _ = viewport.addEventListener!("dblclick", doubleClickClosure)

        let resizeClosure = JSClosure { [weak self] _ in
            guard let self else { return .undefined }
            let resized = self.syncViewportSize()
            if resized {
                self.previewCurrentViewIfPossible()
                self.scheduleVisibleRegionRender()
            }
            return .undefined
        }
        retainedClosures.append(resizeClosure)
        if let windowObject = JSObject.global.window.object {
            _ = windowObject.addEventListener!("resize", resizeClosure)
        }
    }

    private func loadDefaultDatapack() {
        fetchText(at: defaultBundlePath) { [weak self] (result: Result<String, BrowserAppError>) in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.setLoading(false)
                self.setStatus("Failed to load datapack bundle: \(self.describe(error))", isError: true)
            case .success(let text):
                do {
                    let bundle = try JSONDecoder().decode(DatapackBundle.self, from: Data(text.utf8))
                    self.setStatus("Materializing datapack files…")
                    let rootURL = try self.materialize(bundle: bundle)
                    self.scheduleNextTick { [weak self] in
                        self?.initializeDataPack(at: rootURL, bundleText: text)
                    }
                } catch {
                    self.setLoading(false)
                    self.setStatus("Failed to initialize DPReader: \(error)", isError: true)
                }
            }
        }
    }

    private func initializeDataPack(at rootURL: URL, bundleText: String) {
        do {
            setStatus("Parsing datapack…")
            self.dataPack = try DataPack(
                fromRootPath: rootURL,
                loadingOptions: [
                    .noDimensions
                ],
                decodingVersion: .assumedCurrent
            )
            if let dataPack {
                reloadBiomeEditor(using: dataPack)
                reloadStructureEditor(using: dataPack)
            }
            startTileGenerator(bundleText: bundleText)
        } catch {
            self.setLoading(false)
            self.setStatus("Failed to initialize DPReader: \(error)", isError: true)
        }
    }

    private func startTileGenerator(bundleText: String) {
        setStatus("Initializing tile generation worker…")
        Task { [weak self] in
            guard let self else { return }
            do {
                async let initializeTiles: Void = self.tileGenerator.initialize(bundleText: bundleText)
                async let initializeStructures: Void = self.structureGenerator.initialize(bundleText: bundleText)
                try await initializeTiles
                try await initializeStructures
                self.setLoading(false)
                self.setStatus("Datapack ready. Enter a seed and click Render.")
            } catch {
                self.setLoading(false)
                self.setStatus("Failed to start tile generation worker: \(error)", isError: true)
            }
        }
    }

    private func materialize(bundle: DatapackBundle) throws -> URL {
        let rootURL = URL(fileURLWithPath: runtimeDatapackPath, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)

        for file in bundle.files {
            let url = rootURL.appendingPathComponent(file.path)
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            let contents: Data
            if let base64Contents = file.base64Contents {
                guard let decoded = Data(base64Encoded: base64Contents) else {
                    throw BrowserAppError.message("Datapack bundle contains invalid base64 data for \(file.path).")
                }
                contents = decoded
            } else if let text = file.contents {
                contents = Data(text.utf8)
            } else {
                throw BrowserAppError.message("Datapack bundle is missing contents for \(file.path).")
            }
            try contents.write(to: url)
        }

        return rootURL
    }

    private func prepareRender() {
        guard dataPack != nil else {
            setStatus("Datapack is still loading.", isError: true)
            return
        }
        guard let seed = parseSeed(seedInput.value.string ?? "") else {
            setStatus("Enter a valid 64-bit Minecraft seed.", isError: true)
            return
        }

        if currentSeed != seed {
            currentSeed = seed
            tileCache.removeAll(keepingCapacity: true)
            tileRasterCache.removeAll(keepingCapacity: true)
            tileCanvasCache.removeAll(keepingCapacity: true)
            tileAtlas = nil
            fallbackTileAtlas = nil
            visibleStructurePoints.removeAll(keepingCapacity: true)
            visibleLootContainers.removeAll(keepingCapacity: true)
            activeLootStructure = nil
            activeLootRequest += 1
            renderLootPanel(message: nil)
            requestedStructureGeneration = nil
            tileDebugMetrics = TileDebugMetrics()
            updateDebugPanel()
            context.fillStyle = placeholderColor.jsValue
            _ = context.fillRect!(0, 0, viewportWidth, viewportHeight)
        }

        scheduleVisibleRegionRender()
    }

    private func scheduleVisibleRegionRender() {
        guard currentSeed != nil else { return }
        syncViewportSize()
        let viewState = currentViewState()

        latestViewState = viewState
        activeViewGeneration += 1
        pendingTileTimer = nil
        pendingTileJobs.removeAll(keepingCapacity: true)
        guard pendingRenderTimer == nil else { return }

        pendingRenderTimer = JSTimer(millisecondsDelay: 0) { [weak self] in
            guard let self else { return }
            self.pendingRenderTimer = nil
            self.renderVisibleRegion(generation: self.activeViewGeneration)
        }
    }

    private func renderVisibleRegion(generation: Int) {
        guard let seed = currentSeed, let viewState = latestViewState else {
            return
        }
        guard generation == activeViewGeneration else { return }
        if profilingEnabled, profilingMetrics.generation != generation {
            profilingMetrics = TileProfilingMetrics(generation: generation)
        }

        canvas.width = viewState.viewportWidth.jsValue
        canvas.height = viewState.viewportHeight.jsValue
        overlayCanvas.width = viewState.viewportWidth.jsValue
        overlayCanvas.height = viewState.viewportHeight.jsValue
        configureCanvasContext(context)
        configureCanvasContext(overlayContext)

        drawVisibleRegion(seed: seed, viewState: viewState, generation: generation)
        drawGridOverlay(for: viewState)
        scheduleStructureQuery(for: seed, viewState: viewState, generation: generation)
        pruneTileCache(for: seed, around: viewState)

        if pendingTileJobs.isEmpty {
            fallbackTileAtlas = nil
            drawTileAtlas(for: viewState, on: context)
            drawGridOverlay(for: viewState)
            emitProfilingMetrics()
            setStatus(
                "Rendered seed \(displaySeed(seed)) at Y=256, centered on (\(Int(viewState.centerX.rounded())), \(Int(viewState.centerZ.rounded()))) with \(String(format: "%.2f", viewState.blocksPerPixel)) block(s) per pixel."
            )
        } else {
            setStatus(
                "Rendering seed \(displaySeed(seed)) at Y=256, centered on (\(Int(viewState.centerX.rounded())), \(Int(viewState.centerZ.rounded()))). Loading \(pendingTileJobs.count) tile(s)…"
            )
            scheduleNextTileBatch()
        }
    }

    private func drawVisibleRegion(seed: WorldSeed, viewState: ViewState, generation: Int) {
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let scaleKey = scaleKey(for: tileBlocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))

        ensureTileAtlas(
            for: seed,
            scaleKey: scaleKey,
            minTileX: minTileX,
            maxTileX: maxTileX,
            minTileZ: minTileZ,
            maxTileZ: maxTileZ
        )
        drawTileAtlas(for: viewState, on: context)

        var missingJobs: [PendingTileJob] = []
        let centerTileX = Int(floor(viewState.centerX / tileWorldSpan))
        let centerTileZ = Int(floor(viewState.centerZ / tileWorldSpan))

        for tileZ in minTileZ...maxTileZ {
            for tileX in minTileX...maxTileX {
                let cacheKey = TileCacheKey(
                    seed: seed,
                    scaleKey: scaleKey,
                    tileX: tileX,
                    tileZ: tileZ
                )
                if tileCache[cacheKey] == nil {
                    missingJobs.append(
                        PendingTileJob(
                            generation: generation,
                            seed: seed,
                            viewState: viewState,
                            tileBlocksPerPixel: tileBlocksPerPixel,
                            tileX: tileX,
                            tileZ: tileZ
                        )
                    )
                }
            }
        }

        pendingTileJobs = missingJobs.sorted {
            self.spiralSortKey(tileX: $0.tileX, tileZ: $0.tileZ, centerTileX: centerTileX, centerTileZ: centerTileZ)
                < self.spiralSortKey(tileX: $1.tileX, tileZ: $1.tileZ, centerTileX: centerTileX, centerTileZ: centerTileZ)
        }
        updateDebugPanel()
    }

    private func scheduleNextTileBatch() {
        guard pendingTileTimer == nil else { return }
        pendingTileTimer = JSTimer(millisecondsDelay: 0) { [weak self] in
            self?.pendingTileTimer = nil
            self?.processNextTileBatch()
        }
    }

    private func processNextTileBatch() {
        guard !pendingTileJobs.isEmpty else { return }
        guard inFlightTileJob == nil else { return }
        let workerJob = pendingTileJobs.removeFirst()
        guard workerJob.generation == activeViewGeneration, workerJob.seed == currentSeed else {
            scheduleNextTileBatch()
            return
        }
        inFlightTileJob = workerJob
        let generator = tileGenerator
        inFlightTileTask = Task { [weak self] in
            do {
                let result = try await generator.generate(workerJob)
                self?.handleGeneratedTile(result, for: workerJob)
            } catch {
                self?.handleTileGenerationFailure(error, for: workerJob)
            }
        }
        updateDebugPanel()
    }

    private func redrawTileIfCurrent(job: PendingTileJob) {
        guard let currentView = latestViewState else { return }
        guard job.generation == activeViewGeneration else { return }

        let key = TileCacheKey(
            seed: job.seed,
            scaleKey: scaleKey(for: job.tileBlocksPerPixel),
            tileX: job.tileX,
            tileZ: job.tileZ
        )
        drawTileCanvasIntoAtlas(key: key)
        drawTileAtlas(for: currentView, on: context)
        drawGridOverlay(for: currentView)
    }

    private func ensureTileAtlas(
        for seed: WorldSeed,
        scaleKey: Int,
        minTileX: Int,
        maxTileX: Int,
        minTileZ: Int,
        maxTileZ: Int
    ) {
        let margin = 1
        let requiredMinTileX = minTileX - margin
        let requiredMaxTileX = maxTileX + margin
        let requiredMinTileZ = minTileZ - margin
        let requiredMaxTileZ = maxTileZ + margin
        if let tileAtlas,
           tileAtlas.seed == seed,
           tileAtlas.scaleKey == scaleKey,
           tileAtlas.minTileX <= requiredMinTileX,
           tileAtlas.maxTileX >= requiredMaxTileX,
           tileAtlas.minTileZ <= requiredMinTileZ,
           tileAtlas.maxTileZ >= requiredMaxTileZ
        {
            return
        }

        let atlas = TileAtlas(
            seed: seed,
            scaleKey: scaleKey,
            minTileX: requiredMinTileX,
            maxTileX: requiredMaxTileX,
            minTileZ: requiredMinTileZ,
            maxTileZ: requiredMaxTileZ
        )
        preserveTileAtlasAsFallback()
        snapshotCanvas.width = ((atlas.maxTileX - atlas.minTileX + 1) * tileSize).jsValue
        snapshotCanvas.height = ((atlas.maxTileZ - atlas.minTileZ + 1) * tileSize).jsValue
        configureCanvasContext(snapshotContext)
        tileAtlas = atlas

        for tileZ in atlas.minTileZ...atlas.maxTileZ {
            for tileX in atlas.minTileX...atlas.maxTileX {
                drawTileCanvasIntoAtlas(
                    key: TileCacheKey(seed: seed, scaleKey: scaleKey, tileX: tileX, tileZ: tileZ)
                )
            }
        }
    }

    private func drawTileCanvasIntoAtlas(key: TileCacheKey) {
        guard let tileAtlas,
              tileAtlas.seed == key.seed,
              tileAtlas.scaleKey == key.scaleKey,
              key.tileX >= tileAtlas.minTileX,
              key.tileX <= tileAtlas.maxTileX,
              key.tileZ >= tileAtlas.minTileZ,
              key.tileZ <= tileAtlas.maxTileZ
        else {
            return
        }

        let atlasStart = profilingNow()
        guard let sourceCanvas = tileCanvas(for: key) else { return }
        _ = snapshotContext.drawImage!(
            sourceCanvas,
            0,
            0,
            sourceCanvas.width,
            sourceCanvas.height,
            (key.tileX - tileAtlas.minTileX) * tileSize,
            (key.tileZ - tileAtlas.minTileZ) * tileSize,
            tileSize,
            tileSize
        )
        profilingMetrics.atlasMilliseconds += profilingNow() - atlasStart
    }

    private func drawTileAtlas(for viewState: ViewState, on targetContext: JSObject) {
        let viewportStart = profilingNow()
        targetContext.fillStyle = placeholderColor.jsValue
        _ = targetContext.fillRect!(0, 0, viewState.viewportWidth, viewState.viewportHeight)
        if let fallbackTileAtlas {
            drawAtlas(
                fallbackCanvas,
                atlas: fallbackTileAtlas,
                for: viewState,
                on: targetContext
            )
        }
        if let tileAtlas {
            drawAtlas(snapshotCanvas, atlas: tileAtlas, for: viewState, on: targetContext)
        }
        profilingMetrics.viewportMilliseconds += profilingNow() - viewportStart
    }

    private func drawAtlas(
        _ sourceCanvas: JSObject,
        atlas: TileAtlas,
        for viewState: ViewState,
        on targetContext: JSObject
    ) {
        let tileBlocksPerPixel = Double(atlas.scaleKey) / 1024.0
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let atlasWorldStartX = Double(atlas.minTileX * tileSize) * tileBlocksPerPixel
        let atlasWorldStartZ = Double(atlas.minTileZ * tileSize) * tileBlocksPerPixel
        let sourceX = (worldStartX - atlasWorldStartX) / tileBlocksPerPixel
        let sourceZ = (worldStartZ - atlasWorldStartZ) / tileBlocksPerPixel
        let sourceWidth = Double(viewState.viewportWidth) * viewState.blocksPerPixel / tileBlocksPerPixel
        let sourceHeight = Double(viewState.viewportHeight) * viewState.blocksPerPixel / tileBlocksPerPixel

        _ = targetContext.drawImage!(
            sourceCanvas,
            sourceX,
            sourceZ,
            sourceWidth,
            sourceHeight,
            0,
            0,
            viewState.viewportWidth,
            viewState.viewportHeight
        )
    }

    private func configureCanvasContext(_ targetContext: JSObject) {
        targetContext.imageSmoothingEnabled = false.jsValue
    }

    private func invalidateTileRasters() {
        tileRasterCache.removeAll(keepingCapacity: true)
        tileCanvasCache.removeAll(keepingCapacity: true)
        tileAtlas = nil
        fallbackTileAtlas = nil
    }

    private func preserveTileAtlasAsFallback() {
        guard let tileAtlas else { return }
        let width = (tileAtlas.maxTileX - tileAtlas.minTileX + 1) * tileSize
        let height = (tileAtlas.maxTileZ - tileAtlas.minTileZ + 1) * tileSize
        fallbackCanvas.width = width.jsValue
        fallbackCanvas.height = height.jsValue
        configureCanvasContext(fallbackContext)
        _ = fallbackContext.drawImage!(snapshotCanvas, 0, 0)
        fallbackTileAtlas = tileAtlas
    }

    private func tileCanvas(for key: TileCacheKey) -> JSObject? {
        guard let tile = tileCache[key] else { return nil }
        if let canvas = tileCanvasCache[key] {
            return canvas
        }
        let canvas = document.createElement!("canvas").object!
        canvas.width = tile.width.jsValue
        canvas.height = tile.height.jsValue
        guard let canvasContext = canvas.getContext!("2d").object else { return nil }
        configureCanvasContext(canvasContext)
        _ = canvasContext.putImageData!(tileImageData(for: tile, key: key), 0, 0)
        tileCanvasCache[key] = canvas
        return canvas
    }

    private func tileImageData(
        for tile: CachedTile,
        key cacheKey: TileCacheKey
    ) -> JSObject {
        if let imageData = tileRasterCache[cacheKey] {
            return imageData
        }

        let rasterStart = profilingNow()
        var pixels = [UInt8](repeating: 255, count: tile.width * tile.height * 4)
        var resolvedColors: [String: BiomeColor] = [:]
        for (index, paletteIndex) in tile.biomeIndices.enumerated() {
            let biomeID = tile.palette[Int(paletteIndex)]
            let color: BiomeColor
            if let cached = resolvedColors[biomeID] {
                color = cached
            } else {
                let resolved = resolvedBiomeColor(for: biomeID)
                resolvedColors[biomeID] = resolved
                color = resolved
            }

            let offset = index * 4
            pixels[offset] = color.red
            pixels[offset + 1] = color.green
            pixels[offset + 2] = color.blue
        }

        let source = JSUInt8ClampedArray(pixels)
        let imageData = JSObject.global.ImageData.object!.new(source, tile.width, tile.height)
        tileRasterCache[cacheKey] = imageData
        profilingMetrics.rasterMilliseconds += profilingNow() - rasterStart
        return imageData
    }

    private func profilingNow() -> Double {
        guard profilingEnabled else { return 0.0 }
        return JSObject.global.performance.object?.now?().number ?? 0.0
    }

    private func emitProfilingMetrics() {
        guard profilingEnabled else { return }
        let summary =
            "Profile generation \(profilingMetrics.generation): "
                + "sampling=\(String(format: "%.1f", profilingMetrics.sampledBiomeMilliseconds))ms "
                + "palette=\(String(format: "%.1f", profilingMetrics.paletteMilliseconds))ms "
                + "raster=\(String(format: "%.1f", profilingMetrics.rasterMilliseconds))ms "
                + "atlas=\(String(format: "%.1f", profilingMetrics.atlasMilliseconds))ms "
                + "viewport=\(String(format: "%.1f", profilingMetrics.viewportMilliseconds))ms"
        setStatus(summary)
    }

    private func setDragging(_ dragging: Bool) {
        guard let classList = viewport.classList.object else { return }
        if dragging {
            _ = classList.add!("dragging")
        } else {
            _ = classList.remove!("dragging")
        }
    }

    @discardableResult
    private func syncViewportSize() -> Bool {
        guard let rect = viewport.getBoundingClientRect!().object else { return false }
        guard let width = rect.width.number, let height = rect.height.number else { return false }

        let nextWidth = max(1, Int(width.rounded(.down)))
        let nextHeight = max(1, Int(height.rounded(.down)))
        guard nextWidth != viewportWidth || nextHeight != viewportHeight else {
            return false
        }

        viewportWidth = nextWidth
        viewportHeight = nextHeight
        canvas.width = nextWidth.jsValue
        canvas.height = nextHeight.jsValue
        overlayCanvas.width = nextWidth.jsValue
        overlayCanvas.height = nextHeight.jsValue
        configureCanvasContext(context)
        configureCanvasContext(overlayContext)
        return true
    }

    private func currentViewState() -> ViewState {
        ViewState(
            centerX: viewCenterX,
            centerZ: viewCenterZ,
            blocksPerPixel: max(0.125, viewBlocksPerPixel),
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
    }

    private func zoom(atClientX clientX: Double, clientY: Double, factor: Double) {
        let rectObject = viewport.getBoundingClientRect!().object
        let pointerX = clientX - (rectObject?.left.number ?? 0.0)
        let pointerY = clientY - (rectObject?.top.number ?? 0.0)
        let previousBlocksPerPixel = viewBlocksPerPixel
        let worldX = viewCenterX + (pointerX - Double(viewportWidth) / 2.0) * previousBlocksPerPixel
        let worldZ = viewCenterZ + (pointerY - Double(viewportHeight) / 2.0) * previousBlocksPerPixel

        viewBlocksPerPixel = min(256.0, max(0.125, viewBlocksPerPixel * factor))
        viewCenterX = worldX - (pointerX - Double(viewportWidth) / 2.0) * viewBlocksPerPixel
        viewCenterZ = worldZ - (pointerY - Double(viewportHeight) / 2.0) * viewBlocksPerPixel

        previewCurrentViewIfPossible()
        scheduleVisibleRegionRender()
    }

    private func previewCurrentViewIfPossible() {
        let viewState = currentViewState()
        drawTileAtlas(for: viewState, on: context)
        drawGridOverlay(for: viewState)
    }

    private func setLoading(_ loading: Bool) {
        renderButton.disabled = loading.jsValue
        seedInput.disabled = loading.jsValue
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusElement.innerText = text.jsValue
        statusElement.className = (isError ? "status error" : "status").jsValue
    }

    private func updateDebugPanel() {
        if let tileX = tileDebugMetrics.tileX,
           let tileZ = tileDebugMetrics.tileZ,
           let blocksPerPixel = tileDebugMetrics.blocksPerPixel
        {
            debugLastTileElement.innerText =
                "(\(tileX), \(tileZ)) at \(String(format: "%.3g", blocksPerPixel)) bpp".jsValue
        } else {
            debugLastTileElement.innerText = "Waiting for a render".jsValue
        }

        debugGenerationTimeElement.innerText = formatDebugDuration(tileDebugMetrics.generationMilliseconds).jsValue
        debugRenderTimeElement.innerText = formatDebugDuration(tileDebugMetrics.renderMilliseconds).jsValue
        debugPendingTilesElement.innerText = "\(pendingTileJobs.count)".jsValue
        debugCachedTilesElement.innerText = "\(tileCache.count)".jsValue
    }

    private func formatDebugDuration(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "--" }
        return String(format: "%.1f ms", milliseconds)
    }

    private func fetchText(at path: String, completion: @escaping (Result<String, BrowserAppError>) -> Void) {
        let promise = JSObject.global.fetch!(path).object!

        let responseClosure = JSClosure { [weak self] args in
            guard let self, let response = args.first?.object else {
                completion(.failure(.message("Missing fetch response.")))
                return .undefined
            }

            let textPromise = response.text!().object!
            let textClosure = JSClosure { textArgs in
                completion(.success(textArgs.first?.string ?? ""))
                return .undefined
            }
            let textErrorClosure = JSClosure { [weak self] errorArgs in
                completion(.failure(.message(self?.jsErrorString(errorArgs.first) ?? "Unknown text decode error.")))
                return .undefined
            }
            self.retainedClosures.append(contentsOf: [textClosure, textErrorClosure])
            _ = textPromise.then!(textClosure, textErrorClosure)
            return .undefined
        }

        let errorClosure = JSClosure { [weak self] args in
            completion(.failure(.message(self?.jsErrorString(args.first) ?? "Unknown fetch error.")))
            return .undefined
        }

        retainedClosures.append(contentsOf: [responseClosure, errorClosure])
        _ = promise.then!(responseClosure, errorClosure)
    }

    private func scheduleNextTick(_ body: @escaping () -> Void) {
        pendingTimer = JSTimer(millisecondsDelay: 0) { [weak self] in
            self?.pendingTimer = nil
            body()
        }
    }

    private func spiralSortKey(tileX: Int, tileZ: Int, centerTileX: Int, centerTileZ: Int) -> (Int, Int, Int) {
        let dx = tileX - centerTileX
        let dz = tileZ - centerTileZ
        let ring = max(abs(dx), abs(dz))
        if ring == 0 {
            return (0, 0, 0)
        }

        if dx == ring && dz > -ring {
            return (ring, 0, dz + ring)
        }
        if dz == ring && dx < ring {
            return (ring, 1, ring - dx)
        }
        if dx == -ring && dz < ring {
            return (ring, 2, ring - dz)
        }
        return (ring, 3, dx + ring)
    }

    private func scaleKey(for blocksPerPixel: Double) -> Int {
        Int((max(0.125, blocksPerPixel) * 1024.0).rounded())
    }

    private func tileBlocksPerPixel(for blocksPerPixel: Double) -> Double {
        let clamped = min(256.0, max(0.125, blocksPerPixel))
        let exponent = floor(log2(clamped))
        return min(256.0, max(0.125, pow(2.0, exponent)))
    }

    private func pruneTileCache(for seed: WorldSeed, around viewState: ViewState) {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let worldMarginX = Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldMarginZ = Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minScale = max(0.125, viewState.blocksPerPixel * 0.5)
        let maxScale = min(256.0, viewState.blocksPerPixel * 2.0)

        let previousTileKeys = Set(tileCache.keys)
        tileCache = tileCache.filter { key, _ in
            guard key.seed == seed else { return false }

            let keyBlocksPerPixel = Double(key.scaleKey) / 1024.0
            guard keyBlocksPerPixel >= minScale, keyBlocksPerPixel <= maxScale else {
                return false
            }

            let tileWorldSpan = Double(tileSize) * keyBlocksPerPixel
            let tileStartX = Double(key.tileX * tileSize) * keyBlocksPerPixel
            let tileStartZ = Double(key.tileZ * tileSize) * keyBlocksPerPixel
            let tileEndX = tileStartX + tileWorldSpan
            let tileEndZ = tileStartZ + tileWorldSpan

            return
                tileEndX >= worldStartX - worldMarginX
                && tileStartX <= worldEndX + worldMarginX
                && tileEndZ >= worldStartZ - worldMarginZ
                && tileStartZ <= worldEndZ + worldMarginZ
        }
        let retainedTileKeys = Set(tileCache.keys)
        tileRasterCache = tileRasterCache.filter { retainedTileKeys.contains($0.key) }
        tileCanvasCache = tileCanvasCache.filter { retainedTileKeys.contains($0.key) }
        if previousTileKeys != retainedTileKeys {
            tileAtlas = nil
        }
    }

    private func reloadStructureEditor(using dataPack: DataPack) {
        let structureIDs = dataPack.structureSetRegistry.entries().map(\.key.name).sorted()
        loadedStructureIDs = structureIDs
        let loadedStructureSet = Set(structureIDs)
        structureColors = structureColors.filter { loadedStructureSet.contains($0.key) }
        enabledStructureSets = enabledStructureSets.filter { loadedStructureSet.contains($0.key) }
        structureSetSpacings = [:]

        for structureID in structureIDs where structureColors[structureID] == nil {
            structureColors[structureID] = defaultStructureSetColor(for: structureID, using: dataPack)
        }
        for structureID in structureIDs where enabledStructureSets[structureID] == nil {
            enabledStructureSets[structureID] = true
        }
        for entry in dataPack.structureSetRegistry.entries() {
            guard let data = try? JSONEncoder().encode(entry.value),
                  let encoded = try? JSONDecoder().decode(EncodedStructureSet.self, from: data),
                  let spacing = encoded.placement.spacing
            else { continue }
            structureSetSpacings[entry.key.name] = spacing
        }
        renderStructureEditor()
    }

    private func renderStructureEditor() {
        structureRowElements.removeAll(keepingCapacity: true)
        structureListElement.innerHTML = "".jsValue
        guard !loadedStructureIDs.isEmpty else {
            setStructureSummary("No structures are loaded.", isError: false)
            structureEmptyElement.hidden = false.jsValue
            return
        }

        structureEmptyElement.hidden = true.jsValue
        setStructureSummary("Loaded \(loadedStructureIDs.count) structure set(s).", isError: false)
        for structureID in loadedStructureIDs {
            let row = document.createElement!("div").object!
            row.className = "biome-row".jsValue

            let header = document.createElement!("div").object!
            header.className = "biome-row-header".jsValue
            let swatch = document.createElement!("span").object!
            swatch.className = "biome-swatch".jsValue
            _ = header.appendChild!(swatch)
            let name = document.createElement!("span").object!
            name.className = "biome-name".jsValue
            name.innerText = structureID.jsValue
            _ = header.appendChild!(name)
            _ = row.appendChild!(header)

            let enabledInput = document.createElement!("input").object!
            enabledInput.type = "checkbox".jsValue
            enabledInput.className = "structure-enabled-input".jsValue
            enabledInput.title = "Render this structure set".jsValue
            enabledInput.ariaLabel = "Render \(structureID)".jsValue
            let enabledClosure = JSClosure { [weak self, enabledInput] _ in
                self?.applyStructureEnabledChange(for: structureID, enabled: enabledInput.checked.boolean ?? false)
                return .undefined
            }
            retainedClosures.append(enabledClosure)
            _ = enabledInput.addEventListener!("change", enabledClosure)
            _ = row.appendChild!(enabledInput)

            let colorInput = document.createElement!("input").object!
            colorInput.type = "color".jsValue
            colorInput.className = "structure-color-input".jsValue
            let inputClosure = JSClosure { [weak self, colorInput] _ in
                self?.applyStructureColorChange(for: structureID, cssHex: colorInput.value.string ?? "")
                return .undefined
            }
            retainedClosures.append(inputClosure)
            _ = colorInput.addEventListener!("input", inputClosure)
            _ = row.appendChild!(colorInput)
            _ = structureListElement.appendChild!(row)
            structureRowElements[structureID] = StructureRowElements(
                swatch: swatch,
                enabledInput: enabledInput,
                colorInput: colorInput
            )
            syncStructureRow(for: structureID)
        }
    }

    private func applyStructureColorChange(for structureID: String, cssHex: String) {
        guard let color = colorFromCSSHex(cssHex) else { return }
        structureColors[structureID] = color
        syncStructureRow(for: structureID)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
        }
    }

    private func applyStructureEnabledChange(for structureID: String, enabled: Bool) {
        enabledStructureSets[structureID] = enabled
        syncStructureRow(for: structureID)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
            scheduleLatestStructureQueryIfNeeded()
        }
    }

    private func resetStructureColorsToDefaults() {
        guard !loadedStructureIDs.isEmpty, let dataPack else {
            setStructureSummary("No structures are loaded.", isError: true)
            return
        }
        for structureID in loadedStructureIDs {
            structureColors[structureID] = defaultStructureSetColor(for: structureID, using: dataPack)
            enabledStructureSets[structureID] = true
            syncStructureRow(for: structureID)
        }
        setStructureSummary("Reset \(loadedStructureIDs.count) structure colour(s) to defaults.", isError: false)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
        }
    }

    private func syncStructureRow(for structureID: String) {
        guard let row = structureRowElements[structureID], let color = structureColors[structureID] else { return }
        row.swatch.style.object?.backgroundColor = color.cssHex.jsValue
        row.enabledInput.checked = (enabledStructureSets[structureID] ?? true).jsValue
        row.colorInput.value = color.cssHex.jsValue
    }

    private func setStructureSummary(_ text: String, isError: Bool) {
        structureSummaryElement.innerText = text.jsValue
        structureSummaryElement.className = (isError ? "status error" : "status").jsValue
    }

    private func colorFromCSSHex(_ cssHex: String) -> BiomeColor? {
        guard cssHex.count == 7, cssHex.first == "#" else { return nil }
        guard
            let red = UInt8(cssHex.dropFirst().prefix(2), radix: 16),
            let green = UInt8(cssHex.dropFirst(3).prefix(2), radix: 16),
            let blue = UInt8(cssHex.dropFirst(5).prefix(2), radix: 16)
        else {
            return nil
        }
        return BiomeColor(red: red, green: green, blue: blue)
    }

    private func reloadBiomeEditor(using dataPack: DataPack) {
        let biomeIDs = dataPack.biomeRegistry.entries().map(\.key.name).sorted()
        loadedBiomeIDs = biomeIDs

        let loadedBiomeSet = Set(biomeIDs)
        biomeColors = biomeColors.filter { loadedBiomeSet.contains($0.key) }
        biomeColorCache = biomeColorCache.filter { loadedBiomeSet.contains($0.key) }

        for biomeID in biomeIDs where biomeColors[biomeID] == nil {
            let color = vanillaBiomeDefaults[biomeID] ?? generatedBiomeColor(for: biomeID)
            biomeColors[biomeID] = color
            biomeColorCache[biomeID] = color.cssHex
        }

        renderBiomeEditor()
    }

    private func renderBiomeEditor() {
        biomeRowElements.removeAll(keepingCapacity: true)
        biomeListElement.innerHTML = "".jsValue

        if loadedBiomeIDs.isEmpty {
            setBiomeSummary("No biomes are loaded.", isError: false)
            biomeEmptyElement.hidden = false.jsValue
            return
        }

        setBiomeSummary(defaultBiomeSummaryText(), isError: false)
        biomeEmptyElement.hidden = true.jsValue

        for biomeID in loadedBiomeIDs {
            let row = makeBiomeRow(for: biomeID)
            biomeRowElements[biomeID] = row.elements
            _ = biomeListElement.appendChild!(row.container)
            syncBiomeRow(for: biomeID)
        }
    }

    private func makeBiomeRow(for biomeID: String) -> (container: JSObject, elements: BiomeRowElements) {
        let row = document.createElement!("div").object!
        row.className = "biome-row".jsValue

        let header = document.createElement!("div").object!
        header.className = "biome-header".jsValue

        let swatch = document.createElement!("div").object!
        swatch.className = "biome-swatch".jsValue
        _ = header.appendChild!(swatch)

        let name = document.createElement!("div").object!
        name.className = "biome-name".jsValue
        name.innerText = biomeID.jsValue
        _ = header.appendChild!(name)
        _ = row.appendChild!(header)

        let colorInput = document.createElement!("input").object!
        colorInput.type = "color".jsValue
        colorInput.className = "structure-color-input".jsValue
        let inputClosure = JSClosure { [weak self, colorInput] _ in
            self?.applyBiomeColorChange(for: biomeID, cssHex: colorInput.value.string ?? "")
            return .undefined
        }
        retainedClosures.append(inputClosure)
        _ = colorInput.addEventListener!("input", inputClosure)
        _ = row.appendChild!(colorInput)

        return (
            row,
            BiomeRowElements(
                swatch: swatch,
                colorInput: colorInput
            )
        )
    }

    private func applyBiomeColorChange(for biomeID: String, cssHex: String) {
        guard let color = colorFromCSSHex(cssHex) else { return }

        guard biomeColors[biomeID] != color else {
            syncBiomeRow(for: biomeID)
            return
        }

        biomeColors[biomeID] = color
        biomeColorCache[biomeID] = color.cssHex
        syncBiomeRow(for: biomeID)
        invalidateTileRasters()
        scheduleVisibleRegionRender()
    }

    private func resetBiomeColorsToDefaults() {
        guard !loadedBiomeIDs.isEmpty else {
            setBiomeSummary("No biomes are loaded.", isError: true)
            return
        }

        for biomeID in loadedBiomeIDs {
            let color = vanillaBiomeDefaults[biomeID] ?? generatedBiomeColor(for: biomeID)
            biomeColors[biomeID] = color
            biomeColorCache[biomeID] = color.cssHex
            syncBiomeRow(for: biomeID)
        }

        setBiomeSummary("Reset \(loadedBiomeIDs.count) biome color(s) to defaults.", isError: false)
        invalidateTileRasters()
        scheduleVisibleRegionRender()
    }

    private func handleBiomeImportSelection() {
        guard let files = biomeImportInput.files.object else { return }
        guard let file = files[0].object else {
            biomeImportInput.value = "".jsValue
            return
        }

        let textPromise = file.text!().object!
        let successClosure = JSClosure { [weak self] args in
            guard let self else { return .undefined }
            self.biomeImportInput.value = "".jsValue
            self.importBiomeColors(from: args.first?.string ?? "")
            return .undefined
        }
        let errorClosure = JSClosure { [weak self] args in
            self?.biomeImportInput.value = "".jsValue
            self?.setBiomeSummary("Failed to import biome colors: \(self?.jsErrorString(args.first) ?? "Unknown file read error.")", isError: true)
            return .undefined
        }
        retainedClosures.append(contentsOf: [successClosure, errorClosure])
        _ = textPromise.then!(successClosure, errorClosure)
    }

    private func importBiomeColors(from text: String) {
        guard !loadedBiomeIDs.isEmpty else {
            setBiomeSummary("No biomes are loaded.", isError: true)
            return
        }

        let loadedBiomeSet = Set(loadedBiomeIDs)
        var applied = 0
        var unknown = 0
        var malformed = 0
        var updatedBiomeIDs: [String] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = String(rawLine).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let components = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard components.count == 4 else {
                malformed += 1
                continue
            }

            let biomeID = namespacedBiomeID(from: String(components[0]))
            guard loadedBiomeSet.contains(biomeID) else {
                unknown += 1
                continue
            }

            guard
                let red = parseBiomeColorComponent(String(components[1])),
                let green = parseBiomeColorComponent(String(components[2])),
                let blue = parseBiomeColorComponent(String(components[3]))
            else {
                malformed += 1
                continue
            }

            let color = BiomeColor(red: red, green: green, blue: blue)
            biomeColors[biomeID] = color
            biomeColorCache[biomeID] = color.cssHex
            updatedBiomeIDs.append(biomeID)
            applied += 1
        }

        for biomeID in Set(updatedBiomeIDs) {
            syncBiomeRow(for: biomeID)
        }

        if applied > 0 {
            invalidateTileRasters()
            scheduleVisibleRegionRender()
        }

        var fragments: [String] = []
        if applied > 0 {
            fragments.append("Imported \(applied) biome color(s).")
        }
        if unknown > 0 {
            fragments.append("Ignored \(unknown) unknown biome entr\(unknown == 1 ? "y" : "ies").")
        }
        if malformed > 0 {
            fragments.append("Skipped \(malformed) malformed line(s).")
        }
        if fragments.isEmpty {
            fragments.append("No biome colors were imported.")
        }

        setBiomeSummary(fragments.joined(separator: " "), isError: applied == 0)
    }

    private func exportBiomeColors(usingCubiomesFormat: Bool) {
        guard !loadedBiomeIDs.isEmpty else {
            setBiomeSummary("No biomes are loaded.", isError: true)
            return
        }

        let lines = loadedBiomeIDs.map { biomeID -> String in
            let color = resolvedBiomeColor(for: biomeID)
            let exportedID: String
            if usingCubiomesFormat, vanillaBiomeDefaults[biomeID] != nil, biomeID.hasPrefix("minecraft:") {
                exportedID = String(biomeID.dropFirst("minecraft:".count))
            } else {
                exportedID = biomeID
            }

            if usingCubiomesFormat {
                return "\(exportedID) \(color.red) \(color.green) \(color.blue)"
            } else {
                return String(format: "\(exportedID) 0x%02X 0x%02X 0x%02X", color.red, color.green, color.blue)
            }
        }

        let contents = lines.joined(separator: "\n") + "\n"
        let encodedContents = JSObject.global.encodeURIComponent!(contents).string ?? ""
        let anchor = document.createElement!("a").object!
        anchor.href = "data:text/plain;charset=utf-8,\(encodedContents)".jsValue
        anchor.download = (usingCubiomesFormat ? "biome-colors-cubiomes.txt" : "biome-colors.txt").jsValue
        _ = document.body.object?.appendChild!(anchor)
        _ = anchor.click!()
        _ = document.body.object?.removeChild!(anchor)

        setBiomeSummary("Exported \(loadedBiomeIDs.count) biome color(s)\(usingCubiomesFormat ? " in Cubiomes format." : ".")", isError: false)
    }

    private func namespacedBiomeID(from rawID: String) -> String {
        rawID.contains(":") ? rawID : "minecraft:\(rawID)"
    }

    private func parseBiomeColorComponent(_ raw: String) -> UInt8? {
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt8(raw.dropFirst(2), radix: 16)
        }
        guard let value = Int(raw), value >= 0, value <= 255 else {
            return nil
        }
        return UInt8(value)
    }

    private func defaultBiomeSummaryText() -> String {
        "Loaded \(loadedBiomeIDs.count) biome(s). Edit colour per biome."
    }

    private func setBiomeSummary(_ text: String, isError: Bool) {
        biomeSummaryElement.innerText = text.jsValue
        biomeSummaryElement.className = (isError ? "status error" : "status").jsValue
    }

    private func drawGridOverlay(for viewState: ViewState) {
        _ = overlayContext.clearRect!(0, 0, viewState.viewportWidth, viewState.viewportHeight)
        drawTileGrid(for: viewState, on: overlayContext)
        drawTileGridLabels(for: viewState, on: overlayContext)
        drawStructurePoints(for: viewState)
        drawLootContainers(for: viewState)
    }

    private func scheduleStructureQuery(for seed: WorldSeed, viewState: ViewState, generation: Int) {
        requestedStructureGeneration = generation
        guard inFlightStructureTask == nil else { return }

        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let query = StructureQuery(
            seed: seed,
            minX: clampedWorldCoordinate(floor(worldStartX)),
            maxX: clampedWorldCoordinate(ceil(worldEndX)),
            minZ: clampedWorldCoordinate(floor(worldStartZ)),
            maxZ: clampedWorldCoordinate(ceil(worldEndZ)),
            enabledStructureSets: enabledStructureSetIDs(),
            minimumSpacingBlocks: minimumStructureSpacingBlocks(for: viewState)
        )
        let structureGenerator = self.structureGenerator
        inFlightStructureTask = Task { [weak self] in
            do {
                let points = try await structureGenerator.structures(in: query)
                self?.handleStructureQuery(points, for: generation, seed: seed)
            } catch {
                self?.handleStructureQueryFailure(error, for: generation)
            }
        }
    }

    private func handleStructureQuery(_ points: [StructurePoint], for generation: Int, seed: WorldSeed) {
        inFlightStructureTask = nil
        guard generation == activeViewGeneration, seed == currentSeed else {
            scheduleLatestStructureQueryIfNeeded()
            return
        }
        visibleStructurePoints = points
        setStructureSummary("Showing \(points.count) structure start\(points.count == 1 ? "" : "s") in this view.", isError: false)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
            scheduleConcentricStructureQuery(for: seed, viewState: viewState, generation: generation)
        }
    }

    private func scheduleConcentricStructureQuery(for seed: WorldSeed, viewState: ViewState, generation: Int) {
        guard inFlightConcentricStructureTask == nil else { return }
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let query = StructureQuery(
            seed: seed,
            minX: clampedWorldCoordinate(floor(worldStartX)),
            maxX: clampedWorldCoordinate(ceil(worldEndX)),
            minZ: clampedWorldCoordinate(floor(worldStartZ)),
            maxZ: clampedWorldCoordinate(ceil(worldEndZ)),
            enabledStructureSets: enabledStructureSetIDs(),
            minimumSpacingBlocks: minimumStructureSpacingBlocks(for: viewState)
        )
        let structureGenerator = self.structureGenerator
        inFlightConcentricStructureTask = Task { [weak self] in
            do {
                let points = try await structureGenerator.concentricStructures(in: query)
                self?.handleConcentricStructureQuery(points, for: generation, seed: seed)
            } catch {
                self?.handleConcentricStructureQueryFailure(error, for: generation)
            }
        }
    }

    private func handleConcentricStructureQuery(_ points: [StructurePoint], for generation: Int, seed: WorldSeed) {
        inFlightConcentricStructureTask = nil
        guard generation == activeViewGeneration, seed == currentSeed else { return }
        visibleStructurePoints = Array(Set(visibleStructurePoints).union(points)).sorted {
            ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID)
        }
        setStructureSummary("Showing \(visibleStructurePoints.count) structure start\(visibleStructurePoints.count == 1 ? "" : "s") in this view.", isError: false)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
        }
    }

    private func handleConcentricStructureQueryFailure(_ error: Error, for generation: Int) {
        inFlightConcentricStructureTask = nil
        guard generation == activeViewGeneration else { return }
        // Random-spread structures are already rendered. Keep that useful result if the optional
        // ring enumeration cannot complete for a particular datapack.
        setStructureSummary("Showing \(visibleStructurePoints.count) starts; ring structures failed to locate: \(error)", isError: true)
    }

    private func handleStructureQueryFailure(_ error: Error, for generation: Int) {
        inFlightStructureTask = nil
        guard generation == activeViewGeneration else {
            scheduleLatestStructureQueryIfNeeded()
            return
        }
        setStructureSummary("Failed to locate structures: \(error)", isError: true)
    }

    private func scheduleLatestStructureQueryIfNeeded() {
        guard let seed = currentSeed, let viewState = latestViewState else { return }
        scheduleStructureQuery(for: seed, viewState: viewState, generation: activeViewGeneration)
    }

    private func clampedWorldCoordinate(_ value: Double) -> Int32 {
        if value <= Double(Int32.min) { return Int32.min }
        if value >= Double(Int32.max) { return Int32.max }
        return Int32(value)
    }

    private func drawStructurePoints(for viewState: ViewState) {
        guard !visibleStructurePoints.isEmpty else { return }
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let pointSize = max(4.0, min(9.0, 6.0 / sqrt(viewState.blocksPerPixel)))
        for point in visibleStructurePoints {
            guard shouldRenderStructureSet(point.setID, in: viewState) else { continue }
            let screenX = (Double(point.x) - worldStartX) / viewState.blocksPerPixel
            let screenZ = (Double(point.z) - worldStartZ) / viewState.blocksPerPixel
            guard screenX >= -pointSize, screenX <= Double(viewState.viewportWidth) + pointSize,
                  screenZ >= -pointSize, screenZ <= Double(viewState.viewportHeight) + pointSize
            else {
                continue
            }
            overlayContext.fillStyle = "#000000".jsValue
            _ = overlayContext.fillRect!(
                screenX - pointSize / 2.0 - 1.0,
                screenZ - pointSize / 2.0 - 1.0,
                pointSize + 2.0,
                pointSize + 2.0
            )
            overlayContext.fillStyle = structureColor(for: point.setID).cssHex.jsValue
            _ = overlayContext.fillRect!(screenX - pointSize / 2.0, screenZ - pointSize / 2.0, pointSize, pointSize)
        }
    }

    private func drawLootContainers(for viewState: ViewState) {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let size = max(5.0, min(11.0, 7.0 / sqrt(viewState.blocksPerPixel)))
        for container in visibleLootContainers {
            let screenX = (Double(container.x) - worldStartX) / viewState.blocksPerPixel
            let screenZ = (Double(container.z) - worldStartZ) / viewState.blocksPerPixel
            overlayContext.fillStyle = "#000000".jsValue
            _ = overlayContext.fillRect!(screenX - size / 2.0 - 1.5, screenZ - size / 2.0 - 1.5, size + 3.0, size + 3.0)
            overlayContext.fillStyle = "#FFF2A8".jsValue
            _ = overlayContext.fillRect!(screenX - size / 2.0, screenZ - size / 2.0, size, size)
        }
    }

    private func drawTileGrid(for viewState: ViewState, on targetContext: JSObject) {
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))

        targetContext.fillStyle = gridLineColor.jsValue

        for tileX in minTileX...maxTileX + 1 {
            let screenX = Int(floor((Double(tileX * tileSize) * tileBlocksPerPixel - worldStartX) / viewState.blocksPerPixel))
            _ = targetContext.fillRect!(screenX, 0, 1, viewState.viewportHeight)
        }

        for tileZ in minTileZ...maxTileZ + 1 {
            let screenZ = Int(floor((Double(tileZ * tileSize) * tileBlocksPerPixel - worldStartZ) / viewState.blocksPerPixel))
            _ = targetContext.fillRect!(0, screenZ, viewState.viewportWidth, 1)
        }
    }

    private func drawTileGridLabels(for viewState: ViewState, on targetContext: JSObject) {
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))

        targetContext.fillStyle = gridLabelColor.jsValue
        targetContext.font = "11px SFMono-Regular, Menlo, monospace".jsValue
        targetContext.textBaseline = "top".jsValue

        for tileZ in minTileZ...maxTileZ + 1 {
            let worldGridZ = Double(tileZ * tileSize) * tileBlocksPerPixel
            let screenZ = Int(floor((worldGridZ - worldStartZ) / viewState.blocksPerPixel))
            guard screenZ < viewState.viewportHeight else { continue }

            for tileX in minTileX...maxTileX + 1 {
                let worldGridX = Double(tileX * tileSize) * tileBlocksPerPixel
                let screenX = Int(floor((worldGridX - worldStartX) / viewState.blocksPerPixel))
                guard screenX < viewState.viewportWidth else { continue }

                let label = "\(formattedGridCoordinate(worldGridX)), \(formattedGridCoordinate(worldGridZ))"
                _ = targetContext.fillText!(label, screenX + 4, screenZ + 4)
            }
        }
    }

    private func formattedGridCoordinate(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 {
            return String(Int(rounded))
        }

        var text = String(format: "%.2f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) {
            text.removeLast()
        }
        return text
    }

    private func updateTooltip(forClientX clientX: Double, clientY: Double) {
        let viewState = currentViewState()
        let local = localPointerPosition(clientX: clientX, clientY: clientY)
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldX = worldStartX + local.x * viewState.blocksPerPixel
        let worldZ = worldStartZ + local.y * viewState.blocksPerPixel
        let blockX = Int(floor(worldX))
        let blockZ = Int(floor(worldZ))
        let tooltipText: String
        if let container = lootContainer(nearScreenX: local.x, screenZ: local.y, in: viewState) {
            let loot = container.loot.isEmpty ? "(No resolved items)" : container.loot.joined(separator: "\n")
            tooltipText = "\(container.block)\nX: \(container.x), Y: \(container.y), Z: \(container.z)\n\(loot)"
        } else if let structure = structurePoint(nearScreenX: local.x, screenZ: local.y, in: viewState) {
            tooltipText = "Set: \(structure.setID)\nStructure: \(structure.structureID)\nX: \(structure.x), Z: \(structure.z)"
        } else {
            let biomeText = biomeNameAt(worldX: worldX, worldZ: worldZ, in: viewState) ?? "Loading biome…"
            tooltipText = "\(biomeText)\nX: \(blockX), Z: \(blockZ)"
        }

        tooltipElement.innerText = tooltipText.jsValue
        tooltipElement.hidden = false.jsValue
        tooltipElement.style.object?.left = "\(Int(local.x.rounded(.down)) + 14)px".jsValue
        tooltipElement.style.object?.top = "\(Int(local.y.rounded(.down)) + 14)px".jsValue
    }

    private func hideTooltip() {
        tooltipElement.hidden = true.jsValue
    }

    private func selectMapItem(atClientX clientX: Double, clientY: Double) {
        let viewState = currentViewState()
        let local = localPointerPosition(clientX: clientX, clientY: clientY)
        if let container = lootContainer(nearScreenX: local.x, screenZ: local.y, in: viewState) {
            showLootPage()
            selectLootContainer(container)
            return
        }
        selectStructure(atClientX: clientX, clientY: clientY)
    }

    private func selectStructure(atClientX clientX: Double, clientY: Double) {
        guard let seed = currentSeed else { return }
        let viewState = currentViewState()
        let local = localPointerPosition(clientX: clientX, clientY: clientY)
        guard let structure = structurePoint(nearScreenX: local.x, screenZ: local.y, in: viewState) else { return }
        let generation = activeViewGeneration
        let generator = structureGenerator
        activeLootRequest += 1
        let requestID = activeLootRequest
        visibleLootContainers.removeAll(keepingCapacity: true)
        activeLootStructure = structure
        renderLootPanel(message: "Generating loot for \(structure.structureID)…")
        showLootPage()
        // This method is entered directly from a JavaScript event callback. Submit the CPU work
        // explicitly to the dedicated executor; relying on an implicit actor hop here trips the
        // Swift WASM runtime's executor precondition before `loot` can begin.
        let workerTask = generator.scheduleLoot(for: structure, seed: seed)
        inFlightLootTask = Task { @MainActor [weak self] in
            do {
                let containers = try await workerTask.value
                guard let self,
                      requestID == self.activeLootRequest,
                      generation == self.activeViewGeneration,
                      seed == self.currentSeed
                else { return }
                self.visibleLootContainers = containers
                self.drawGridOverlay(for: self.currentViewState())
                if containers.isEmpty {
                    self.renderLootPanel(message: "This structure has no supported loot containers.")
                } else {
                    self.renderLootPanel(message: nil)
                }
            } catch {
                guard let self, requestID == self.activeLootRequest else { return }
                self.renderLootPanel(message: "Could not generate structure loot: \(error)", isError: true)
            }
        }
    }

    private func showLootPage() {
        _ = JSObject.global.dappermapShowPage?("loot".jsValue)
    }

    private func renderLootPanel(message: String?, isError: Bool = false) {
        lootInfoElement.hidden = false.jsValue
        lootContainerDetails.removeAll(keepingCapacity: true)
        lootListElement.innerHTML = "".jsValue
        lootMessageElement.innerText = (message ?? "").jsValue
        lootMessageElement.hidden = (message == nil).jsValue
        lootMessageElement.className = (isError ? "status error" : "status").jsValue
        guard !visibleLootContainers.isEmpty else { return }
        for container in visibleLootContainers {
            let details = document.createElement!("details").object!
            details.className = "loot-container".jsValue
            let summary = document.createElement!("summary").object!
            summary.innerText = "\(container.block) at (\(container.x), \(container.y), \(container.z))".jsValue
            _ = details.appendChild!(summary)
            let items = document.createElement!("ul").object!
            items.className = "loot-items".jsValue
            for item in container.loot {
                let row = document.createElement!("li").object!
                row.innerText = item.jsValue
                _ = items.appendChild!(row)
            }
            if container.loot.isEmpty {
                let row = document.createElement!("li").object!
                row.innerText = "No resolved items".jsValue
                _ = items.appendChild!(row)
            }
            _ = details.appendChild!(items)
            _ = lootListElement.appendChild!(details)
            lootContainerDetails[container] = details
        }
    }

    private func selectLootContainer(_ container: LootContainerPoint) {
        guard let details = lootContainerDetails[container] else { return }
        details.open = true.jsValue
        _ = details.scrollIntoView?()
    }

    private func localPointerPosition(clientX: Double, clientY: Double) -> (x: Double, y: Double) {
        let rectObject = viewport.getBoundingClientRect!().object
        let localX = clientX - (rectObject?.left.number ?? 0.0)
        let localY = clientY - (rectObject?.top.number ?? 0.0)
        return (
            x: min(max(0.0, localX), Double(viewportWidth)),
            y: min(max(0.0, localY), Double(viewportHeight))
        )
    }

    private func biomeNameAt(worldX: Double, worldZ: Double, in viewState: ViewState) -> String? {
        guard let seed = currentSeed else { return nil }

        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let tileX = Int(floor(worldX / tileWorldSpan))
        let tileZ = Int(floor(worldZ / tileWorldSpan))
        let key = TileCacheKey(
            seed: seed,
            scaleKey: scaleKey(for: tileBlocksPerPixel),
            tileX: tileX,
            tileZ: tileZ
        )
        guard let tile = tileCache[key] else { return nil }

        let tileWorldStartX = Double(tileX * tileSize) * tileBlocksPerPixel
        let tileWorldStartZ = Double(tileZ * tileSize) * tileBlocksPerPixel
        let localX = min(max(Int(floor((worldX - tileWorldStartX) / tileBlocksPerPixel)), 0), tile.width - 1)
        let localZ = min(max(Int(floor((worldZ - tileWorldStartZ) / tileBlocksPerPixel)), 0), tile.height - 1)
        return tile.palette[Int(tile.biomeIndices[localZ * tile.width + localX])]
    }

    private func structurePoint(nearScreenX screenX: Double, screenZ: Double, in viewState: ViewState) -> StructurePoint? {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let hitRadius = max(6.0, min(11.0, 7.0 / sqrt(viewState.blocksPerPixel)))
        return visibleStructurePoints.filter { shouldRenderStructureSet($0.setID, in: viewState) }.min { lhs, rhs in
            let lhsX = (Double(lhs.x) - worldStartX) / viewState.blocksPerPixel
            let lhsZ = (Double(lhs.z) - worldStartZ) / viewState.blocksPerPixel
            let rhsX = (Double(rhs.x) - worldStartX) / viewState.blocksPerPixel
            let rhsZ = (Double(rhs.z) - worldStartZ) / viewState.blocksPerPixel
            let lhsDistance = (lhsX - screenX) * (lhsX - screenX) + (lhsZ - screenZ) * (lhsZ - screenZ)
            let rhsDistance = (rhsX - screenX) * (rhsX - screenX) + (rhsZ - screenZ) * (rhsZ - screenZ)
            return lhsDistance < rhsDistance
        }.flatMap { point in
            let pointX = (Double(point.x) - worldStartX) / viewState.blocksPerPixel
            let pointZ = (Double(point.z) - worldStartZ) / viewState.blocksPerPixel
            let distanceSquared = (pointX - screenX) * (pointX - screenX) + (pointZ - screenZ) * (pointZ - screenZ)
            return distanceSquared <= hitRadius * hitRadius ? point : nil
        }
    }

    private func lootContainer(nearScreenX screenX: Double, screenZ: Double, in viewState: ViewState) -> LootContainerPoint? {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let radius = max(7.0, min(13.0, 8.0 / sqrt(viewState.blocksPerPixel)))
        return visibleLootContainers.min { lhs, rhs in
            let lhsDistance = pow((Double(lhs.x) - worldStartX) / viewState.blocksPerPixel - screenX, 2) + pow((Double(lhs.z) - worldStartZ) / viewState.blocksPerPixel - screenZ, 2)
            let rhsDistance = pow((Double(rhs.x) - worldStartX) / viewState.blocksPerPixel - screenX, 2) + pow((Double(rhs.z) - worldStartZ) / viewState.blocksPerPixel - screenZ, 2)
            return lhsDistance < rhsDistance
        }.flatMap { container in
            let x = (Double(container.x) - worldStartX) / viewState.blocksPerPixel
            let z = (Double(container.z) - worldStartZ) / viewState.blocksPerPixel
            return (x - screenX) * (x - screenX) + (z - screenZ) * (z - screenZ) <= radius * radius ? container : nil
        }
    }

    private func syncBiomeRow(for biomeID: String) {
        guard let row = biomeRowElements[biomeID] else { return }
        let color = resolvedBiomeColor(for: biomeID)
        row.swatch.style.object?.backgroundColor = color.cssHex.jsValue
        row.colorInput.value = color.cssHex.jsValue
    }

    private func resolvedBiomeColor(for biomeID: String) -> BiomeColor {
        if let color = biomeColors[biomeID] {
            return color
        }

        let color = vanillaBiomeDefaults[biomeID] ?? generatedBiomeColor(for: biomeID)
        biomeColors[biomeID] = color
        biomeColorCache[biomeID] = color.cssHex
        return color
    }

    private func generatedBiomeColor(for biomeID: String) -> BiomeColor {
        var hash: UInt32 = 2166136261
        for byte in biomeID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }

        return BiomeColor(
            red: UInt8(64 + (hash & 0x7F)),
            green: UInt8(64 + ((hash >> 7) & 0x7F)),
            blue: UInt8(64 + ((hash >> 14) & 0x7F))
        )
    }

    private func generatedStructureColor(for structureID: String) -> BiomeColor {
        var hash: UInt32 = 2166136261
        for byte in structureID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return BiomeColor(
            red: UInt8(80 + (hash & 0x6F)),
            green: UInt8(80 + ((hash >> 8) & 0x6F)),
            blue: UInt8(80 + ((hash >> 16) & 0x6F))
        )
    }

    private func parseSeed(_ raw: String) -> WorldSeed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let signed = Int64(trimmed) {
            return UInt64(bitPattern: signed)
        }
        return UInt64(trimmed)
    }

    private func displaySeed(_ seed: WorldSeed) -> String {
        String(Int64(bitPattern: seed))
    }

    private func jsErrorString(_ value: JSValue?) -> String {
        guard let value else { return "Unknown JavaScript error." }
        if let text = value.string, !text.isEmpty {
            return text
        }
        if
            let jsonObject = JSObject.global.JSON.object,
            let json = jsonObject.stringify?(value).string,
            !json.isEmpty
        {
            return json
        }
        return "Unknown JavaScript error."
    }

    private func describe(_ error: BrowserAppError) -> String {
        switch error {
        case .message(let message):
            return message
        }
    }

    private func color(for biomeID: String) -> String {
        if let cached = biomeColorCache[biomeID] {
            return cached
        }

        let resolvedColor = resolvedBiomeColor(for: biomeID).cssHex
        biomeColorCache[biomeID] = resolvedColor
        return resolvedColor
    }

    private func structureColor(for structureID: String) -> BiomeColor {
        if let color = structureColors[structureID] {
            return color
        }
        let color = vanillaStructureDefaults[structureID] ?? generatedStructureColor(for: structureID)
        structureColors[structureID] = color
        return color
    }

    private func defaultStructureSetColor(for structureSetID: String, using dataPack: DataPack) -> BiomeColor {
        if let entry = dataPack.structureSetRegistry.entries().first(where: { $0.key.name == structureSetID }),
           let data = try? JSONEncoder().encode(entry.value),
           let encoded = try? JSONDecoder().decode(EncodedStructureSet.self, from: data),
           let structureID = encoded.structures.map(\.structure).first(where: { vanillaStructureDefaults[$0] != nil }),
           let color = vanillaStructureDefaults[structureID]
        {
            return color
        }
        return generatedStructureColor(for: structureSetID)
    }

    private func enabledStructureSetIDs() -> Set<String> {
        Set(loadedStructureIDs.filter { enabledStructureSets[$0] ?? true })
    }

    private func minimumStructureSpacingBlocks(for viewState: ViewState) -> Double {
        Double(tileSize) * tileBlocksPerPixel(for: viewState.blocksPerPixel) / 8.0
    }

    private func shouldRenderStructureSet(_ structureSetID: String, in viewState: ViewState) -> Bool {
        guard enabledStructureSets[structureSetID] ?? true else { return false }
        guard let spacing = structureSetSpacings[structureSetID] else { return true }
        return Double(spacing) * 16.0 >= minimumStructureSpacingBlocks(for: viewState)
    }
}
#endif
