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
public actor NativeGenerationPlatform: DapperMapGenerationPlatform {
    private let workers: [TileGenerationService]
    private var availableWorkers: [Int]
    private var waiters: [CheckedContinuation<Int, Never>] = []
    private var initializedDatapack: (rootURL: URL, packFormat: Version)?
    private var initializingDatapack: (rootURL: URL, packFormat: Version)?
    private var initializationTask: Task<Void, Error>?
    private var stagedRoots: [String: URL] = [:]

    public init(
        threadCount: Int,
        enableDensityCompilation: Bool = ProcessInfo.processInfo.environment["DAPPERMAP_ENABLE_LLVM"] == "1"
    ) {
        let count = max(1, min(32, threadCount))
        workers = (0..<count).map { index in
            // DPReader's LLVM biome JIT takes roughly 14 seconds per shape and is intended for
            // long batch jobs. Interactive AppKit/SDL views rarely amortize that setup cost.
            TileGenerationService(
                samplingBackend: .scalar,
                prefersNativeCompilation: enableDensityCompilation && index == 0
            )
        }
        // `popLast()` should hand the first request to worker zero, the worker configured with
        // LLVM bulk sampling, rather than to the highest-index scalar fallback.
        availableWorkers = Array((0..<count).reversed())
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

        let workers = self.workers
        let loadingRoot = try stageRootIfNeeded(rootURL: standardizedRootURL, packFormat: packFormat)
        let task = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in workers {
                    group.addTask {
                        try await worker.initialize(rootURL: loadingRoot, decodingVersion: packFormat)
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
            releaseWorker(workerIndex)
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
            releaseWorker(workerIndex)
            throw error
        }
    }

    public func generateLoot(
        for structure: MapStructurePresentation,
        seed: Int64
    ) async throws -> [MapLootPresentation] {
        let workerIndex = await acquireWorker()
        do {
            let result = try await workers[workerIndex].loot(
                for: StructurePoint(
                    setID: structure.setID,
                    structureID: structure.structureID,
                    x: structure.x,
                    z: structure.z
                ),
                seed: UInt64(bitPattern: seed)
            )
            releaseWorker(workerIndex)
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
            releaseWorker(workerIndex)
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
        let workerIndex = await acquireWorker()
        do {
            let result = try await workers[workerIndex].searchLoot(query, seed: seed, onProgress: onProgress)
            releaseWorker(workerIndex)
            return result
        } catch {
            releaseWorker(workerIndex)
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

    private func releaseWorker(_ worker: Int) {
        if waiters.isEmpty {
            availableWorkers.append(worker)
        } else {
            waiters.removeFirst().resume(returning: worker)
        }
    }
}
#endif
