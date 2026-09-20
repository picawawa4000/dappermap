import DPReader
import DapperMapCore
import Foundation

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
#elseif canImport(AppKit)
import AppKit
import CoreGraphics
#endif

#if canImport(wasi_pthread)
import wasi_pthread
import WASILibc
#endif
#if !os(WASI)
struct SharedWorldGeneratorKey: Hashable {
    let seed: WorldSeed
    let dimensionID: String
}

/// DPReader permits concurrent generation from a fixed-seed generator when callers use distinct
/// chunks/states. Never reseed this object: an old request can safely finish on its generator
/// after the UI has moved to another seed.
final class SharedNativeWorldGenerator: @unchecked Sendable {
    let key: SharedWorldGeneratorKey
    let generator: WorldGenerator
    let usesNativeBulkSampler: Bool
    let densityCompilationMilliseconds: Double?
    let densityCompilationBackend: String?

    init(
        key: SharedWorldGeneratorKey,
        dataPack: DataPack,
        enableDensityCompilation: Bool
    ) throws {
        self.key = key
        let settingsID: String
        switch key.dimensionID {
        case "minecraft:the_nether", "minecraft:nether": settingsID = "minecraft:nether"
        case "minecraft:the_end", "minecraft:end": settingsID = "minecraft:end"
        default: settingsID = "minecraft:overworld"
        }
        let settings = RegistryKey<NoiseSettings>(referencing: settingsID)
        let start = Date()
        if enableDensityCompilation {
            do {
                generator = try WorldGenerator(
                    withWorldSeed: key.seed,
                    usingDataPacks: [dataPack],
                    usingSettings: settings,
                    compilationBackend: .llvm
                )
                usesNativeBulkSampler = true
                densityCompilationBackend = "LLVM"
                densityCompilationMilliseconds = Date().timeIntervalSince(start) * 1_000.0
                return
            } catch {
                // LLVM is optional; preserve the existing scalar fallback.
            }
        }
        generator = try WorldGenerator(
            withWorldSeed: key.seed,
            usingDataPacks: [dataPack],
            usingSettings: settings
        )
        usesNativeBulkSampler = false
        densityCompilationBackend = nil
        densityCompilationMilliseconds = nil
    }
}

public actor NativeGenerationPlatform: DapperMapGenerationPlatform {
    private let workers: [TileGenerationService]
    private let enableDensityCompilation: Bool
    /// Search workers never service interactive tile or marker-loot requests. This keeps a
    /// potentially long radius search from consuming the map's responsive generation capacity.
    private let lootSearchWorkers: [TileGenerationService]
    private var availableWorkers: [Int]
    private var waiters: [CheckedContinuation<Int, Never>] = []
    private var availableLootSearchWorkers: [Int]
    private var lootSearchWaiters: [CheckedContinuation<Int, Never>] = []
    private var initializedDatapack: (rootURL: URL, packFormat: Version)?
    private var initializingDatapack: (rootURL: URL, packFormat: Version)?
    private var initializationTask: Task<Void, Error>?
    private var stagedRoots: [String: URL] = [:]
    private var sharedDataPack: SharedLoadedDataPack?
    private var sharedWorldGenerators: [SharedWorldGeneratorKey: SharedNativeWorldGenerator] = [:]

    public init(
        threadCount: Int,
        lootSearchThreadCount: Int = 1,
        enableDensityCompilation: Bool = false
    ) {
        self.enableDensityCompilation = enableDensityCompilation
        let count = max(1, min(32, threadCount))
        let searchCount = max(1, min(4, lootSearchThreadCount))
        workers = (0..<count).map { index in
            // DPReader's LLVM biome JIT takes roughly 14 seconds per shape and is intended for
            // long batch jobs. Interactive AppKit/SDL views rarely amortize that setup cost.
            TileGenerationService(
                samplingBackend: .scalar,
                prefersNativeCompilation: enableDensityCompilation && index == 0
            )
        }
        lootSearchWorkers = (0..<searchCount).map { _ in
            TileGenerationService(samplingBackend: .scalar, prefersNativeCompilation: false)
        }
        // `popLast()` should hand the first request to worker zero, the worker configured with
        // LLVM bulk sampling, rather than to the highest-index scalar fallback.
        availableWorkers = Array((0..<count).reversed())
        availableLootSearchWorkers = Array((0..<searchCount).reversed())
    }

    public func initialize(rootURL: URL, packFormat: Version) async throws {
        let standardizedRootURL = rootURL.standardizedFileURL
        let datapack = (rootURL: standardizedRootURL, packFormat: packFormat)
        guard initializedDatapack?.rootURL != datapack.rootURL || initializedDatapack?.packFormat != datapack.packFormat else { return }
        if initializingDatapack?.rootURL == datapack.rootURL,
           initializingDatapack?.packFormat == datapack.packFormat,
           let initializationTask {
            try await initializationTask.value
            return
        }
        if let initializationTask {
            try await initializationTask.value
            if initializedDatapack?.rootURL == datapack.rootURL,
               initializedDatapack?.packFormat == datapack.packFormat { return }
        }

        let loadingRoot = try stageRootIfNeeded(rootURL: standardizedRootURL, packFormat: packFormat)
        // Decoding templates and registry graphs dominates native memory. Load one frozen pack
        // and share it read-only; the fixed-seed WorldGenerator is created only on demand.
        let sharedDataPack = try SharedLoadedDataPack(rootURL: loadingRoot, decodingVersion: packFormat)
        let workers = self.workers + self.lootSearchWorkers
        let task = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in workers {
                    group.addTask {
                        try await worker.initialize(sharedDataPack: sharedDataPack)
                    }
                }
                try await group.waitForAll()
            }
        }
        initializingDatapack = datapack
        initializationTask = task
        do {
            try await task.value
            initializedDatapack = datapack
            self.sharedDataPack = sharedDataPack
            // A generator is backed by registries from its source pack.  Workers have just
            // released their local references during initialization, so drop the old graph too.
            self.sharedWorldGenerators.removeAll(keepingCapacity: false)
            initializingDatapack = nil
            initializationTask = nil
        } catch {
            initializingDatapack = nil
            initializationTask = nil
            throw error
        }
    }

    /// Client jars extracted by DPReader's helper contain the built-in `data/` tree but no root
    /// `pack.mcmeta`. Stage a temporary loading root with the selected format, just as the browser
    /// bundle generator does, without modifying the user's extracted datapack directory.
    private func stageRootIfNeeded(rootURL: URL, packFormat: Version) throws -> URL {
        let metadataURL = rootURL.appendingPathComponent("pack.mcmeta")
        guard !FileManager.default.fileExists(atPath: metadataURL.path) else { return rootURL }

        let key = "\(rootURL.path)#\(packFormat)"
        if let staged = stagedRoots[key] { return staged }
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dappermap-native-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: nil)
        let stagedData = stagingRoot.appendingPathComponent("data", isDirectory: true)
        // Foundation's directory enumeration does not reliably follow directory symlinks on all
        // native platforms, so copy the extracted data tree into the temporary loading root.
        try fileManager.copyItem(
            at: rootURL.appendingPathComponent("data", isDirectory: true),
            to: stagedData
        )
        let pack: [String: Any]
        if packFormat.major < 82 {
            pack = ["pack_format": packFormat.major, "description": "DapperMap vanilla datapack"]
        } else {
            let format = [packFormat.major, packFormat.minor]
            pack = ["min_format": format, "max_format": format, "description": "DapperMap vanilla datapack"]
        }
        let metadata: [String: Any] = ["pack": pack]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try metadataData.write(to: stagingRoot.appendingPathComponent("pack.mcmeta"), options: .atomic)
        stagedRoots[key] = stagingRoot
        return stagingRoot
    }

    public func registryIDs() async -> (biomes: [String], dimensions: [String], structures: [String]) {
        guard let worker = workers.first else { return ([], [], []) }
        return await worker.registryIDs()
    }

    public func generateTile(_ request: MapTileRequest) async throws -> MapTilePresentation {
        let workerIndex = await acquireWorker()
        do {
            try Task.checkCancellation()
            let sharedGenerator = try await sharedWorldGenerator(seed: UInt64(bitPattern: request.seed), dimensionID: request.dimensionID)
            try await workers[workerIndex].use(sharedGenerator: sharedGenerator)
            try Task.checkCancellation()
            let job = PendingTileJob(
                generation: request.generation,
                seed: UInt64(bitPattern: request.seed),
                viewState: ViewState(
                    centerX: request.centerX,
                    centerZ: request.centerZ,
                    blocksPerPixel: request.blocksPerPixel,
                    viewportWidth: request.viewportWidth,
                    viewportHeight: request.viewportHeight
                ),
                tileBlocksPerPixel: request.tileBlocksPerPixel,
                tileX: request.tileX,
                tileZ: request.tileZ,
                sampleY: request.sampleY,
                dimensionID: request.dimensionID,
                enabledStructureSets: request.enabledStructureSets
            )
            let result = try await workers[workerIndex].generate(job)
            await finishWorker(workerIndex)
            return MapTilePresentation(
                generation: request.generation,
                seed: request.seed,
                scaleKey: MapMath.scaleKey(for: request.tileBlocksPerPixel),
                tileX: request.tileX,
                tileZ: request.tileZ,
                width: result.tile.width,
                height: result.tile.height,
                palette: result.tile.palette,
                biomeIndices: result.tile.biomeIndices,
                structures: result.tile.structurePoints.map {
                    MapStructurePresentation(setID: $0.setID, structureID: $0.structureID, x: $0.x, z: $0.z)
                },
                generationMilliseconds: result.generationMilliseconds,
                densityCompilationMilliseconds: result.densityCompilationMilliseconds,
                densityCompilationBackend: result.densityCompilationBackend
            )
        } catch {
            await finishWorker(workerIndex)
            throw error
        }
    }

    public func generateLoot(
        for structure: MapStructurePresentation,
        seed: Int64
    ) async throws -> [MapLootPresentation] {
        let workerIndex = await acquireWorker()
        do {
            try Task.checkCancellation()
            let sharedGenerator = try await sharedWorldGenerator(seed: UInt64(bitPattern: seed), dimensionID: "minecraft:overworld")
            try await workers[workerIndex].use(sharedGenerator: sharedGenerator)
            try Task.checkCancellation()
            let result = try await workers[workerIndex].loot(
                for: StructurePoint(
                    setID: structure.setID,
                    structureID: structure.structureID,
                    x: structure.x,
                    z: structure.z
                ),
                seed: UInt64(bitPattern: seed)
            )
            await finishWorker(workerIndex)
            return result.map {
                MapLootPresentation(
                    block: $0.block,
                    lootTable: $0.lootTable,
                    x: $0.x,
                    y: $0.y,
                    z: $0.z,
                    items: $0.loot
                )
            }
        } catch {
            await finishWorker(workerIndex)
            throw error
        }
    }

    public func searchLoot(_ query: LootSearchQuery, seed: Int64) async throws -> [MapLootPresentation] {
        try await searchLoot(query, seed: seed, onProgress: { _ in })
    }

    public func searchLoot(
        _ query: LootSearchQuery,
        seed: Int64,
        onProgress: @escaping @Sendable (LootSearchProgress) -> Void
    ) async throws -> [MapLootPresentation] {
        let workerIndex = await acquireLootSearchWorker()
        do {
            try Task.checkCancellation()
            let sharedGenerator = try await sharedWorldGenerator(seed: UInt64(bitPattern: seed), dimensionID: query.dimensionID)
            try await lootSearchWorkers[workerIndex].use(sharedGenerator: sharedGenerator)
            try Task.checkCancellation()
            let result = try await lootSearchWorkers[workerIndex].searchLoot(query, seed: seed, onProgress: onProgress)
            await finishLootSearchWorker(workerIndex)
            return result
        } catch {
            await finishLootSearchWorker(workerIndex)
            throw error
        }
    }

    private func acquireWorker() async -> Int {
        if let worker = availableWorkers.popLast() {
            return worker
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func sharedWorldGenerator(seed: WorldSeed, dimensionID: String) async throws -> SharedNativeWorldGenerator {
        guard let sharedDataPack else {
            throw BrowserAppError.message("Structure generation worker is not ready.")
        }
        let key = SharedWorldGeneratorKey(seed: seed, dimensionID: dimensionID)
        if let generator = sharedWorldGenerators[key] { return generator }
        // This is the write side of the shared-generator protocol. Wait until every worker has
        // dropped generator-derived caches before replacing the configuration, so no idle
        // worker can keep a previous density graph alive indefinitely.
        for worker in workers {
            await worker.releaseSharedGenerator()
        }
        for worker in lootSearchWorkers {
            await worker.releaseSharedGenerator()
        }
        sharedWorldGenerators.removeAll(keepingCapacity: true)
        let generator = try SharedNativeWorldGenerator(
            key: key,
            dataPack: sharedDataPack.dataPack,
            enableDensityCompilation: enableDensityCompilation
        )
        sharedWorldGenerators[key] = generator
        return generator
    }

    private func releaseWorker(_ worker: Int) {
        if waiters.isEmpty {
            availableWorkers.append(worker)
        } else {
            waiters.removeFirst().resume(returning: worker)
        }
    }

    private func finishWorker(_ worker: Int) async {
        await workers[worker].finishSharedGeneratorRequest()
        releaseWorker(worker)
    }

    private func acquireLootSearchWorker() async -> Int {
        if let worker = availableLootSearchWorkers.popLast() { return worker }
        return await withCheckedContinuation { lootSearchWaiters.append($0) }
    }

    private func releaseLootSearchWorker(_ worker: Int) {
        if lootSearchWaiters.isEmpty {
            availableLootSearchWorkers.append(worker)
        } else {
            lootSearchWaiters.removeFirst().resume(returning: worker)
        }
    }

    private func finishLootSearchWorker(_ worker: Int) async {
        await lootSearchWorkers[worker].finishSharedGeneratorRequest()
        releaseLootSearchWorker(worker)
    }
}
#endif
