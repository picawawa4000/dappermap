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

    public init(threadCount: Int) {
        let count = max(1, min(32, threadCount))
        workers = (0..<count).map { index in
            TileGenerationService(samplingBackend: .scalar, prefersNativeCompilation: index == 0)
        }
        availableWorkers = Array(0..<count)
    }

    public func initialize(rootURL: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in workers {
                group.addTask {
                    try await worker.initialize(rootURL: rootURL)
                }
            }
            try await group.waitForAll()
        }
    }

    public func registryIDs() async -> (biomes: [String], structures: [String]) {
        guard let worker = workers.first else { return ([], []) }
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
