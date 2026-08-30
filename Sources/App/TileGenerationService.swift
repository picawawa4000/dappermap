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
#if os(WASI)
@MainActor
func webKitNeedsScalarTileSampling() -> Bool {
    guard let userAgent = JSObject.global.navigator.userAgent.string else { return false }
    guard userAgent.contains("AppleWebKit") else { return false }
    return !userAgent.contains("Chrome/")
        && !userAgent.contains("Chromium/")
        && !userAgent.contains("Edg/")
}

enum TileGenerationExecutor {
    case dedicated(WebWorkerDedicatedExecutor)

    var unownedExecutor: UnownedSerialExecutor {
        switch self {
        case .dedicated(let executor):
            return executor.asUnownedSerialExecutor()
        }
    }
}
#endif

/// A retained fused sampler plus caller-owned output storage. TileGenerationService is an actor,
/// so the mutable buffer is only ever accessed by one tile request at a time.
private final class ReusableBiomeTileSampler {
    let sampler: CompiledNoiseRouterBiomeBulkSampler
    private var output: [Int32]

    init(sampler: CompiledNoiseRouterBiomeBulkSampler) {
        self.sampler = sampler
        output = [Int32](repeating: 0, count: sampler.bufferContext.sampleCount)
    }

    func biomeNames(at position: PosInt3D) -> [String] {
        output.withUnsafeMutableBufferPointer { sampler.fill(at: position, into: $0) }
        return output.map { sampler.palette[Int($0)].name }
    }
}

/// Owns one non-thread-safe DPReader generation context. Platforms choose how instances are
/// scheduled: the browser pins one to a Web Worker; native keeps one actor per requested thread.
actor TileGenerationService: DapperMapGenerationPlatform {
#if os(WASI)
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
    private var usesNativeBulkSampler = false
    private var densityCompilationMilliseconds: Double?
    private var densityCompilationBackend: String?
    private var wasmRuntime: BrowserWASMRuntime?
    private var samplers: [TileSamplerKey: ReusableBiomeTileSampler] = [:]
    private var structureSampler: StructurePlacementSampler?
    private var structureSetDescriptors: [StructureSetDescriptor] = []
    private var validatedStructureStarts: [String: String] = [:]
    private var rejectedStructureStarts: Set<String> = []
    private var structureHeightmapSampler: GeneratedStructureHeightmapSampler?
    private var dataPackRoot: URL?
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        serialExecutor.unownedExecutor
    }

    init(serialExecutor: TileGenerationExecutor, samplingBackend: TileSamplingBackend) {
        self.serialExecutor = serialExecutor
        self.samplingBackend = samplingBackend
    }
#else
    private let samplingBackend: TileSamplingBackend
    private let prefersNativeCompilation: Bool
    private let overworldDimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private let overworldNoiseSettings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    private let tileSize = 256
    private var dataPack: DataPack?
    private var currentSeed: WorldSeed?
    private var generator: WorldGenerator?
    private var usesNativeBulkSampler = false
    private var densityCompilationMilliseconds: Double?
    private var densityCompilationBackend: String?
    private var samplers: [TileSamplerKey: ReusableBiomeTileSampler] = [:]
    private var structureSampler: StructurePlacementSampler?
    private var structureSetDescriptors: [StructureSetDescriptor] = []
    private var validatedStructureStarts: [String: String] = [:]
    private var rejectedStructureStarts: Set<String> = []
    private var structureHeightmapSampler: GeneratedStructureHeightmapSampler?
    private var dataPackRoot: URL?

    init(samplingBackend: TileSamplingBackend = .scalar, prefersNativeCompilation: Bool = true) {
        self.samplingBackend = samplingBackend
        self.prefersNativeCompilation = prefersNativeCompilation
    }
#endif

#if os(WASI)
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
#endif

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
                frequency: encoded.placement.frequency,
                structureIDs: encoded.structures.map(\.structure)
            )
        }
        try prewarmCompiledDensityFunctions()
    }

    func initialize(rootURL: URL) throws {
        dataPackRoot = rootURL
        dataPack = try DataPack(
            fromRootPath: rootURL,
            loadingOptions: [.noDimensions],
            decodingVersion: .assumedCurrent
        )
        structureSetDescriptors = try dataPack!.structureSetRegistry.entries().compactMap { entry in
            let data = try JSONEncoder().encode(entry.value)
            let encoded = try JSONDecoder().decode(EncodedStructureSet.self, from: data)
            return StructureSetDescriptor(
                keyName: entry.key.name,
                kind: encoded.placement.type,
                spacing: encoded.placement.spacing,
                frequency: encoded.placement.frequency,
                structureIDs: encoded.structures.map(\.structure)
            )
        }
        try prewarmCompiledDensityFunctions()
    }

    /// Build the generator and all fixed-shape bulk samplers up front. DPReader retains compiled
    /// density graphs across later calls to `setWorldSeed`; each zoom level gets its own bulk
    /// program because its buffer stride and shape are part of the compilation key.
    private func prewarmCompiledDensityFunctions() throws {
        guard let dataPack else { return }
        try configureGenerator(for: 0, using: dataPack)
        guard let generator, usesNativeBulkSampler || samplingBackend == .nestedWASM else { return }
        let strategy: CompilationBackend = samplingBackend == .nestedWASM ? .wasm : .llvm
        for exponent in -3...8 {
            let blocksPerPixel = pow(2.0, Double(exponent))
            let tileSpan = max(1, Int32((Double(tileSize) * blocksPerPixel).rounded()))
            let sampleScale = max(1, Int32((Double(tileSpan) / 128.0).rounded()))
            let sampleWidth = max(1, Int((tileSpan + sampleScale - 1) / sampleScale))
            let key = TileSamplerKey(
                sampleWidth: Int32(sampleWidth), sampleHeight: Int32(sampleWidth), sampleYCount: 1, sampleScale: sampleScale
            )
            if samplers[key] != nil { continue }
            let compiled = try generator.makeBiomeIDBulkSampler(
                for: CompiledDensityFunctionBufferContext(
                    xCount: Int32(sampleWidth), yCount: 1, zCount: Int32(sampleWidth),
                    xStep: sampleScale, yStep: 1, zStep: sampleScale
                ),
                in: overworldDimension,
                strategy: strategy
            )
            samplers[key] = ReusableBiomeTileSampler(sampler: compiled)
        }
        // Force DPReader's cached full-chunk terrain program as well. Structure-start heightmap
        // validation shares this program, so otherwise its first candidate pays the compile cost.
        let warmupChunk = ProtoChunk()
        try generator.generateInto(warmupChunk, at: PosInt2D(x: 0, z: 0))
    }

    func registryIDs() -> (biomes: [String], structures: [String]) {
        guard let dataPack else { return ([], []) }
        return (
            dataPack.biomeRegistry.entries().map(\.key.name).sorted(),
            dataPack.structureSetRegistry.entries().map(\.key.name).sorted()
        )
    }

    func generate(_ job: PendingTileJob) throws -> GeneratedTile {
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }

        try configureGenerator(for: job.seed, using: dataPack)

        let start = Date()
        let generated = try makeTile(
            using: generator!,
            blocksPerPixel: job.tileBlocksPerPixel,
            tileX: job.tileX,
            tileZ: job.tileZ,
            sampleY: job.sampleY
        )
        let structureQuery = StructureQuery(
            seed: job.seed,
            minX: generated.biomeCache.usableMinX,
            maxX: generated.biomeCache.usableMaxX,
            minZ: generated.biomeCache.usableMinZ,
            maxZ: generated.biomeCache.usableMaxZ,
            enabledStructureSets: job.enabledStructureSets ?? Set(structureSetDescriptors.map(\.keyName)),
            minimumSpacingBlocks: Double(tileSize) * job.tileBlocksPerPixel / 8.0
        )
        let structures = try structures(
            in: structureQuery,
            biomeSampler: generated.biomeCache.biome(at:)
        )
        let tile = CachedTile(
            width: generated.tile.width,
            height: generated.tile.height,
            palette: generated.tile.palette,
            biomeIndices: generated.tile.biomeIndices,
            structurePoints: structures?.points ?? [],
            structureMetrics: structures?.metrics ?? StructureProfilingMetrics()
        )
        return GeneratedTile(
            tile: tile,
            generationMilliseconds: Date().timeIntervalSince(start) * 1_000.0,
            densityCompilationMilliseconds: densityCompilationMilliseconds,
            densityCompilationBackend: densityCompilationBackend
        )
    }

    func generateTile(_ request: MapTileRequest) async throws -> MapTilePresentation {
        let result = try generate(PendingTileJob(
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
        ))
        return MapTilePresentation(
            generation: request.generation,
            seed: request.seed,
            scaleKey: Int((request.tileBlocksPerPixel * 1024).rounded()),
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
    }

    func generateLoot(
        for structure: MapStructurePresentation,
        seed: Int64
    ) async throws -> [MapLootPresentation] {
        try loot(
            for: StructurePoint(
                setID: structure.setID,
                structureID: structure.structureID,
                x: structure.x,
                z: structure.z
            ),
            seed: UInt64(bitPattern: seed)
        ).map {
            MapLootPresentation(
                block: $0.block,
                lootTable: $0.lootTable,
                x: $0.x,
                y: $0.y,
                z: $0.z,
                items: $0.loot
            )
        }
    }

    // Structure starts are generated as part of a tile after its biome cache exists. Keep the
    // former viewport-wide entry point unavailable so callers cannot bypass that cache.
    func structures(in query: StructureQuery) throws -> StructureQueryResult? {
        throw BrowserAppError.message("Structure starts must be generated as part of a tile.")
    }

    func structures(
        in query: StructureQuery,
        biomeSampler: @escaping (PosInt3D) throws -> RegistryKey<Biome>?
    ) throws -> StructureQueryResult? {
        let profilingStart = Date()
        var metrics = StructureProfilingMetrics()
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }
        try configureGenerator(for: query.seed, using: dataPack)
        guard let generator, let structureSampler else { return nil }
        let validationContext = try makeValidationContext(
            using: generator,
            biomeSampler: biomeSampler
        )

        var points = Set<StructurePoint>()
        for descriptor in structureSetDescriptors where query.enabledStructureSets.contains(descriptor.keyName) {
            let samples: [StructurePlacementSample]
            switch descriptor.kind {
            case .randomSpread:
                guard let spacing = descriptor.spacing, spacing > 0 else { continue }
                let worldSpacing = Double(spacing) * 16.0
                let effectiveSpacing = descriptor.frequency == nil
                    ? worldSpacing
                    : max(worldSpacing, minimumFrequencyStructureWorldSpacing)
                guard effectiveSpacing >= query.minimumSpacingBlocks else { continue }
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
                let samplingStart = Date()
                for regionZ in minRegionZ...maxRegionZ {
                    for regionX in minRegionX...maxRegionX {
                        if let sample = try structureSampler.sampleStructureSet(
                            inRegion: PosInt2D(x: regionX, z: regionZ),
                            for: RegistryKey(referencing: descriptor.keyName)
                        ) {
                            generated.append(sample)
                            metrics.candidates += 1
                        }
                    }
                }
                metrics.samplingMilliseconds += Date().timeIntervalSince(samplingStart) * 1_000.0
                samples = generated
            case .concentricRings:
                // Concentric-ring placements are generated in the same tile pass as random
                // spread placements so strongholds are retained in the tile cache and use the
                // already-generated biome sampler for validation.
                let samplingStart = Date()
                samples = try structureSampler.sampleAllPlacements(
                    for: RegistryKey(referencing: descriptor.keyName)
                )
                metrics.samplingMilliseconds += Date().timeIntervalSince(samplingStart) * 1_000.0
                metrics.candidates += samples.count
            }

            let validationStart = Date()
            for sample in samples where pointIsVisible(sample.blockPos, in: query) {
                // Monument validation scans a 59×59×59 biome volume. Most random-spread
                // candidates are not even in a deep ocean, so reject those before asking the
                // placement sampler to perform its authoritative surrounding-ocean check.
                if descriptor.keyName == "minecraft:ocean_monuments" {
                    let biome = try biomeSampler(PosInt3D(
                        x: sample.chunkPos.x &* 16 &+ 8,
                        y: 63,
                        z: sample.chunkPos.z &* 16 &+ 8
                    ))
                    guard let biome,
                          try structureSampler.resolveStructure(for: sample, biome: biome) != nil
                    else { continue }
                }
                let validationKey = "\(descriptor.keyName):\(sample.chunkPos.x),\(sample.chunkPos.z)"
                let structureID: String
                if let cached = validatedStructureStarts[validationKey] {
                    metrics.cacheHits += 1
                    structureID = cached
                } else if rejectedStructureStarts.contains(validationKey) {
                    metrics.cacheHits += 1
                    metrics.rejected += 1
                    continue
                } else {
                    let startValidationStart = Date()
                    let resolvedStructure = try structureSampler.resolveStructure(
                        for: sample,
                        validatingWith: validationContext
                    )
                    let startValidationMilliseconds = Date().timeIntervalSince(startValidationStart) * 1_000.0
                    let profiledStructureIDs = resolvedStructure.map { [$0.name] } ?? descriptor.structureIDs
                    for structureID in profiledStructureIDs {
                        var typeMetrics = metrics.byStructureType[structureID, default: StructureTypeProfilingMetrics()]
                        typeMetrics.starts += 1
                        typeMetrics.totalMilliseconds += startValidationMilliseconds
                        metrics.byStructureType[structureID] = typeMetrics
                    }
                    guard let structure = resolvedStructure else {
                        rejectedStructureStarts.insert(validationKey)
                        metrics.rejected += 1
                        continue
                    }
                    structureID = structure.name
                    validatedStructureStarts[validationKey] = structureID
                    metrics.accepted += 1
                }
                points.insert(StructurePoint(
                    setID: descriptor.keyName,
                    structureID: structureID,
                    x: sample.blockPos.x,
                    z: sample.blockPos.z
                ))
            }
            metrics.validationMilliseconds += Date().timeIntervalSince(validationStart) * 1_000.0
        }
        metrics.totalMilliseconds = Date().timeIntervalSince(profilingStart) * 1_000.0
        return StructureQueryResult(
            points: points.sorted { ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID) },
            metrics: metrics
        )
    }

    /// Ring placements are deliberately a second pass: DPReader enumerates all rings before it
    /// returns any stronghold, which should not hold up the normal map and random-spread overlay.
    func concentricStructures(in query: StructureQuery) throws -> StructureQueryResult? {
        throw BrowserAppError.message("Structure starts must be generated as part of a tile.")
    }

    func concentricStructures(
        in query: StructureQuery,
        biomeSampler: @escaping (PosInt3D) throws -> RegistryKey<Biome>?
    ) throws -> StructureQueryResult? {
        let profilingStart = Date()
        var metrics = StructureProfilingMetrics()
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }
        try configureGenerator(for: query.seed, using: dataPack)
        guard let generator, let structureSampler else { return nil }
        let validationContext = try makeValidationContext(
            using: generator,
            biomeSampler: biomeSampler
        )

        var points = Set<StructurePoint>()
        for descriptor in structureSetDescriptors
        where descriptor.kind == .concentricRings && query.enabledStructureSets.contains(descriptor.keyName) {
            let samplingStart = Date()
            let samples = try structureSampler.sampleAllPlacements(
                for: RegistryKey(referencing: descriptor.keyName)
            )
            metrics.samplingMilliseconds += Date().timeIntervalSince(samplingStart) * 1_000.0
            metrics.candidates += samples.count
            let validationStart = Date()
            for sample in samples where pointIsVisible(sample.blockPos, in: query) {
                let validationKey = "\(descriptor.keyName):\(sample.chunkPos.x),\(sample.chunkPos.z)"
                let structureID: String
                if let cached = validatedStructureStarts[validationKey] {
                    metrics.cacheHits += 1
                    structureID = cached
                } else if rejectedStructureStarts.contains(validationKey) {
                    metrics.cacheHits += 1
                    metrics.rejected += 1
                    continue
                } else {
                    let startValidationStart = Date()
                    let resolvedStructure = try structureSampler.resolveStructure(
                        for: sample,
                        validatingWith: validationContext
                    )
                    let startValidationMilliseconds = Date().timeIntervalSince(startValidationStart) * 1_000.0
                    let profiledStructureIDs = resolvedStructure.map { [$0.name] } ?? descriptor.structureIDs
                    for structureID in profiledStructureIDs {
                        var typeMetrics = metrics.byStructureType[structureID, default: StructureTypeProfilingMetrics()]
                        typeMetrics.starts += 1
                        typeMetrics.totalMilliseconds += startValidationMilliseconds
                        metrics.byStructureType[structureID] = typeMetrics
                    }
                    guard let structure = resolvedStructure else {
                        rejectedStructureStarts.insert(validationKey)
                        metrics.rejected += 1
                        continue
                    }
                    structureID = structure.name
                    validatedStructureStarts[validationKey] = structureID
                    metrics.accepted += 1
                }
                points.insert(StructurePoint(
                    setID: descriptor.keyName,
                    structureID: structureID,
                    x: sample.blockPos.x,
                    z: sample.blockPos.z
                ))
            }
            metrics.validationMilliseconds += Date().timeIntervalSince(validationStart) * 1_000.0
        }
        metrics.totalMilliseconds = Date().timeIntervalSince(profilingStart) * 1_000.0
        return StructureQueryResult(
            points: points.sorted { ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID) },
            metrics: metrics
        )
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

        let needsGeneratedTerrain = encodedDefinition.type == "minecraft:jigsaw"
            || encodedDefinition.type == "minecraft:buried_treasure"
            || !terrainChunkCoordinates.isEmpty
        let terrainGenerator: WorldGenerator?
        if needsGeneratedTerrain {
            try configureGenerator(for: seed, using: dataPack)
            guard let generator else {
                throw BrowserAppError.message("Structure generation worker is not ready.")
            }
            terrainGenerator = generator
        } else {
            terrainGenerator = nil
        }
        if !terrainChunkCoordinates.isEmpty, let terrainGenerator {
            for coordinate in terrainChunkCoordinates {
                let values = coordinate.split(separator: ",", maxSplits: 1).compactMap { Int32($0) }
                guard values.count == 2 else { continue }
                let chunk = ProtoChunk()
                try terrainGenerator.generateInto(chunk, at: PosInt2D(x: values[0], z: values[1]))
                terrainChunks[coordinate] = chunk
            }
        }

        let air = BlockState(id: "minecraft:air")
        let terrain = BlockState(id: "minecraft:stone")
        let context = StructureGenerationContext(
            seaLevel: 63,
            minimumWorldY: -64,
            usingDataPacks: [dataPack],
            blockSampler: { position in
                let chunkX = floorDivide(position.x, by: 16)
                let chunkZ = floorDivide(position.z, by: 16)
                let coordinate = "\(chunkX),\(chunkZ)"
                if terrainChunks[coordinate] == nil, let terrainGenerator {
                    let chunk = ProtoChunk()
                    try? terrainGenerator.generateInto(chunk, at: PosInt2D(x: chunkX, z: chunkZ))
                    terrainChunks[coordinate] = chunk
                }
                guard let chunk = terrainChunks[coordinate],
                      position.y >= chunk.minY,
                      position.y < chunk.minY + chunk.height else {
                    return air
                }
                let localPosition = PosInt3D(
                    x: position.x - chunkX * 16,
                    y: position.y - chunk.minY,
                    z: position.z - chunkZ * 16
                )
                return chunk.block(atLocal: localPosition)
            }
        )
        // The map intentionally shows biome-valid placement candidates. Mansion layouts need a
        // terrain height only for their vertical anchor, but our coarse density preview can
        // disagree with vanilla's final surface at a corner. Use the vanilla flat-reference
        // anchor so candidate loot remains deterministic and matches DPReader's layout.
        let lootContext: StructureGenerationContext
        if encodedDefinition.type == "minecraft:woodland_mansion" {
            let mansionTerrain = BlockState(id: "minecraft:stone")
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
        func loadLootTable(_ identifier: String) throws -> LootTable {
            let parts = identifier.split(separator: ":", maxSplits: 1)
            let namespace = parts.count == 2 ? String(parts[0]) : "minecraft"
            let path = parts.count == 2 ? String(parts[1]) : identifier
            let tableURL = rootURL.appendingPathComponent("data/\(namespace)/loot_table/\(path).json")
            return try JSONDecoder().decode(LootTable.self, from: Data(contentsOf: tableURL))
        }

        let table = try loadLootTable(tableID)
        let items = try table.generateLoot(withContext: LootContext(
            random: CheckedRandom(seed: UInt64(bitPattern: seed)),
            enchantmentResources: enchantmentResources
        ), resolvingTables: { identifier in
            try loadLootTable(identifier)
        })
        func titleCaseID(_ identifier: String) -> String {
            let path = identifier.split(separator: ":", maxSplits: 1).last.map(String.init) ?? identifier
            return path.split(separator: "_").map { part in
                guard let first = part.first else { return "" }
                return String(first).uppercased() + part.dropFirst()
            }.joined(separator: " ")
        }

        func stringValue(_ value: JSONValue?) -> String? {
            guard case .string(let value)? = value else { return nil }
            return value
        }

        func integerValue(_ value: JSONValue?) -> Int64? {
            guard case .integer(let value)? = value else { return nil }
            return value
        }

        func metadata(for item: ItemStack) -> [String] {
            let reflected = Dictionary(uniqueKeysWithValues: Mirror(reflecting: item).children.compactMap { child in
                child.label.map { ($0, child.value) }
            })
            guard let components = reflected["components"] as? [String: JSONValue] else { return [] }
            var metadata: [String] = []

            if case .object(let enchantmentComponent)? = components["minecraft:enchantments"],
               case .object(let levels)? = enchantmentComponent["levels"] {
                let enchantments = levels.compactMap { id, value -> String? in
                    guard let level = integerValue(value) else { return nil }
                    return "\(id) \(level)"
                }.sorted()
                if !enchantments.isEmpty {
                    metadata.append("Enchantments: " + enchantments.joined(separator: ", "))
                }
            }

            if case .object(let potionComponent)? = components["minecraft:potion_contents"],
               let potion = stringValue(potionComponent["potion"]) {
                metadata.append("Potion: \(titleCaseID(potion))")
            }

            if case .array(let effects)? = components["minecraft:suspicious_stew_effects"] {
                let descriptions = effects.compactMap { effect -> String? in
                    guard case .object(let values) = effect,
                          let id = stringValue(values["id"]) else { return nil }
                    if let duration = integerValue(values["duration"]) {
                        return "\(titleCaseID(id)) (\(duration) ticks)"
                    }
                    return titleCaseID(id)
                }
                if !descriptions.isEmpty {
                    metadata.append("Effects: " + descriptions.joined(separator: ", "))
                }
            }
            return metadata
        }

        var formattedItems: [String] = []
        for item in items {
            let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: item).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            })
            let name = fields["itemName"] ?? "unknown"
            let count = Int(fields["count"] ?? "") ?? 0
            let suffix = metadata(for: item)
            formattedItems.append(
                suffix.isEmpty
                    ? "\(count) × \(name)"
                    : "\(count) × \(name) — " + suffix.joined(separator: "; ")
            )
        }
        return formattedItems
    }

    private func configureGenerator(for seed: WorldSeed, using dataPack: DataPack) throws {
        if let generator {
            if currentSeed != seed {
                // DPReader retains compiled graphs and search trees across seed changes.
                try generator.setWorldSeed(seed)
                currentSeed = seed
                samplers.removeAll(keepingCapacity: true)
                structureSampler = StructurePlacementSampler(withWorldSeed: seed, usingDataPacks: [dataPack])
                validatedStructureStarts.removeAll(keepingCapacity: true)
                rejectedStructureStarts.removeAll(keepingCapacity: true)
                structureHeightmapSampler = nil
            } else {
                return
            }
            return
        } else {
            let compilationStart = Date()
            densityCompilationMilliseconds = nil
            densityCompilationBackend = nil
            switch samplingBackend {
            case .nestedWASM:
#if os(WASI)
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
                densityCompilationBackend = "WebAssembly"
#else
                throw BrowserAppError.message("Nested WebAssembly sampling is only available in the browser.")
#endif
            case .scalar:
#if !os(WASI)
                if prefersNativeCompilation {
                    do {
                        generator = try WorldGenerator(
                            withWorldSeed: seed,
                            usingDataPacks: [dataPack],
                            usingSettings: overworldNoiseSettings,
                            compilationBackend: .llvm
                        )
                        usesNativeBulkSampler = true
                        densityCompilationBackend = "LLVM"
                    } catch {
                        generator = try WorldGenerator(
                            withWorldSeed: seed,
                            usingDataPacks: [dataPack],
                            usingSettings: overworldNoiseSettings
                        )
                        usesNativeBulkSampler = false
                    }
                } else {
                    generator = try WorldGenerator(
                        withWorldSeed: seed,
                        usingDataPacks: [dataPack],
                        usingSettings: overworldNoiseSettings
                    )
                    usesNativeBulkSampler = false
                }
#else
                generator = try WorldGenerator(
                    withWorldSeed: seed,
                    usingDataPacks: [dataPack],
                    usingSettings: overworldNoiseSettings
                )
                usesNativeBulkSampler = false
#endif
#if os(WASI)
                wasmRuntime?.invalidate()
                wasmRuntime = nil
#endif
            }
            if densityCompilationBackend != nil {
                densityCompilationMilliseconds = Date().timeIntervalSince(compilationStart) * 1_000.0
            }
            currentSeed = seed
            samplers.removeAll(keepingCapacity: true)
            structureSampler = StructurePlacementSampler(withWorldSeed: seed, usingDataPacks: [dataPack])
            validatedStructureStarts.removeAll(keepingCapacity: true)
            rejectedStructureStarts.removeAll(keepingCapacity: true)
            structureHeightmapSampler = nil
        }
    }

    private func pointIsVisible(_ point: PosInt2D, in query: StructureQuery) -> Bool {
        point.x >= query.minX && point.x <= query.maxX
            && point.z >= query.minZ && point.z <= query.maxZ
    }

    private func makeValidationContext(
        using generator: WorldGenerator,
        biomeSampler: @escaping (PosInt3D) throws -> RegistryKey<Biome>?
    ) throws -> StructureStartValidationContext {
        let terrain: GeneratedStructureHeightmapSampler
        if let existing = structureHeightmapSampler {
            terrain = existing
        } else {
            terrain = GeneratedStructureHeightmapSampler(
                worldGenerator: generator,
                seaLevel: 63,
                minimumWorldY: -64,
                maximumWorldY: 319,
                dimension: overworldDimension
            )
            structureHeightmapSampler = terrain
        }
        return StructureStartValidationContext(
            dimension: overworldDimension,
            seaLevel: 63,
            minimumWorldY: -64,
            maximumWorldY: 319,
            heightmapSampler: terrain.height,
            biomeSampler: biomeSampler
        )
    }

    private func compiledBiomeNames(
        using generator: WorldGenerator,
        sampleWidth: Int32,
        sampleHeight: Int32,
        sampleYCount: Int32 = 1,
        sampleScale: Int32,
        at position: PosInt3D,
        strategy: CompilationBackend
    ) throws -> [String] {
        // The key includes both fixed shape and stride, matching DPReader's retained-sampler
        // contract. The associated output buffer is reused for every subsequent tile.
        let key = TileSamplerKey(sampleWidth: sampleWidth, sampleHeight: sampleHeight, sampleYCount: sampleYCount, sampleScale: sampleScale)
        let sampler: ReusableBiomeTileSampler
        if let existing = samplers[key] {
            sampler = existing
        } else {
            let compiled = try generator.makeBiomeIDBulkSampler(
                for: CompiledDensityFunctionBufferContext(
                    xCount: sampleWidth, yCount: sampleYCount, zCount: sampleHeight,
                    xStep: sampleScale, yStep: 1, zStep: sampleScale
                ),
                in: overworldDimension,
                strategy: strategy
            )
            sampler = ReusableBiomeTileSampler(sampler: compiled)
            samplers[key] = sampler
        }
        return sampler.biomeNames(at: position)
    }

    private func makeTile(
        using generator: WorldGenerator,
        blocksPerPixel: Double,
        tileX: Int,
        tileZ: Int,
        sampleY: Int32
    ) throws -> (tile: CachedTile, biomeCache: TileBiomeCache) {
        // Keep the normal map path at a fixed 128-by-128 output shape. The level of detail lives
        // in the sampling stride, which lets one fused bulk program serve every tile at a scale.
        // At sub-quarter-block zoom a stride below one is impossible, so retain exact pixels.
        let tileSpan = max(1, Int32((Double(tileSize) * blocksPerPixel).rounded()))
        let sampleScale = max(1, Int32((Double(tileSpan) / 128.0).rounded()))
        let sampleWidth = max(1, Int((tileSpan + sampleScale - 1) / sampleScale))
        let startX = Int32(tileX) &* tileSpan
        let startZ = Int32(tileZ) &* tileSpan
        let biomeIDs: [String]
        switch samplingBackend {
        case .nestedWASM:
            biomeIDs = try compiledBiomeNames(
                using: generator,
                sampleWidth: Int32(sampleWidth),
                sampleHeight: Int32(sampleWidth),
                sampleScale: sampleScale,
                at: PosInt3D(x: startX, y: sampleY, z: startZ),
                strategy: .wasm
            )
        case .scalar:
            if usesNativeBulkSampler {
                biomeIDs = try compiledBiomeNames(
                    using: generator,
                    sampleWidth: Int32(sampleWidth),
                    sampleHeight: Int32(sampleWidth),
                    sampleScale: sampleScale,
                    at: PosInt3D(x: startX, y: sampleY, z: startZ),
                    strategy: .llvm
                )
            } else {
                let extent = Int32(sampleWidth) * sampleScale
                guard let biomes = try generator.generateBiomesInSquare(
                    from: PosInt2D(x: startX, z: startZ),
                    to: PosInt2D(x: startX + extent, z: startZ + extent),
                    atY: sampleY,
                    in: overworldDimension,
                    scale: sampleScale,
                    forceNoBaking: sampleScale == 1
                ) else {
                    throw BrowserAppError.message("The overworld biome sampler returned no data.")
                }
                biomeIDs = biomes.map(\.name)
            }
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

        // Structure validation is quart-aligned and may inspect a 29-block radius around an
        // ocean monument. Generate a padded quart grid in the same biome pass so validation can
        // read the results without asking WorldGenerator to sample individual positions again.
        let structureScale: Int32 = 4
        let structureMinY: Int32 = -64
        let structureYCount: Int32 = 96
        let structureMargin: Int32 = 32
        // Lazy per-column caching avoids the former 3D allocation, so structure sampling can
        // cover the complete visible tile at every zoom level.
        let sampledStructureSpan = tileSpan
        let sampledStructureOriginX = startX &+ (tileSpan &- sampledStructureSpan) / 2
        let sampledStructureOriginZ = startZ &+ (tileSpan &- sampledStructureSpan) / 2
        let structureStartX = floorDivide(sampledStructureOriginX &- structureMargin, by: structureScale) * structureScale
        let structureStartZ = floorDivide(sampledStructureOriginZ &- structureMargin, by: structureScale) * structureScale
        let structureEndX = sampledStructureOriginX &+ sampledStructureSpan &+ structureMargin
        let structureEndZ = sampledStructureOriginZ &+ sampledStructureSpan &+ structureMargin
        let structureWidth = Int(floorDivide(structureEndX &- structureStartX &+ structureScale &- 1, by: structureScale))
        let structureHeight = Int(floorDivide(structureEndZ &- structureStartZ &+ structureScale &- 1, by: structureScale))
        let biomeCache = TileBiomeCache(
            startX: structureStartX,
            startZ: structureStartZ,
            scale: structureScale,
            width: structureWidth,
            height: structureHeight,
            minY: structureMinY,
            yCount: Int(structureYCount)
        ) { [self] x, z in
            switch samplingBackend {
            case .nestedWASM:
                return try compiledBiomeNames(using: generator, sampleWidth: 1, sampleHeight: 1, sampleYCount: structureYCount, sampleScale: structureScale, at: PosInt3D(x: x, y: structureMinY, z: z), strategy: .wasm)
            case .scalar where usesNativeBulkSampler:
                return try compiledBiomeNames(using: generator, sampleWidth: 1, sampleHeight: 1, sampleYCount: structureYCount, sampleScale: structureScale, at: PosInt3D(x: x, y: structureMinY, z: z), strategy: .llvm)
            case .scalar:
                return try (0..<structureYCount).map { yOffset in
                    guard let biome = try generator.generateBiomesInSquare(from: PosInt2D(x: x, z: z), to: PosInt2D(x: x &+ structureScale, z: z &+ structureScale), atY: structureMinY &+ yOffset &* 4, in: overworldDimension, scale: structureScale)?.first else {
                        throw BrowserAppError.message("The overworld structure biome sampler returned no data.")
                    }
                    return biome.name
                }
            }
        }
        let tile = CachedTile(
            width: sampleWidth,
            height: sampleWidth,
            palette: palette,
            biomeIndices: indices,
            structurePoints: [],
            structureMetrics: StructureProfilingMetrics()
        )
        return (tile, biomeCache)
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
