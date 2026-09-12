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
    let palette: [String]
    private var output: [Int32]

    init(sampler: CompiledNoiseRouterBiomeBulkSampler) {
        self.sampler = sampler
        palette = sampler.palette.map(\.name)
        output = [Int32](repeating: 0, count: sampler.bufferContext.sampleCount)
    }

    func biomeNames(at position: PosInt3D) -> [String] {
        output.withUnsafeMutableBufferPointer { sampler.fill(at: position, into: $0) }
        return output.map { palette[Int($0)] }
    }

    func tile(at position: PosInt3D) -> (palette: [String], indices: [UInt16]) {
        output.withUnsafeMutableBufferPointer { sampler.fill(at: position, into: $0) }
        var compactPalette = ["minecraft:plains"]
        var compactIndexBySamplerIndex: [Int32: UInt16] = [:]
        if let plainsIndex = palette.firstIndex(of: "minecraft:plains") {
            compactIndexBySamplerIndex[Int32(plainsIndex)] = 0
        }
        var indices = [UInt16](repeating: 0, count: output.count)
        for (outputIndex, samplerIndex) in output.enumerated() {
            if let compactIndex = compactIndexBySamplerIndex[samplerIndex] {
                indices[outputIndex] = compactIndex
                continue
            }
            precondition(compactPalette.count <= Int(UInt16.max), "A tile contains too many biome types.")
            let compactIndex = UInt16(compactPalette.count)
            compactPalette.append(palette[Int(samplerIndex)])
            compactIndexBySamplerIndex[samplerIndex] = compactIndex
            indices[outputIndex] = compactIndex
        }
        return (compactPalette, indices)
    }
}

/// Owns one non-thread-safe DPReader generation context. Platforms choose how instances are
/// scheduled: the browser pins one to a Web Worker; native keeps one actor per requested thread.
actor TileGenerationService: DapperMapGenerationPlatform {
    // Vanilla declares its playable dimensions in the normal world preset rather than as
    // `data/*/dimension` entries, so they do not appear in `dimensionsRegistry`.
    private static let vanillaDimensionIDs: Set<String> = [
        "minecraft:overworld",
        "minecraft:the_nether",
        "minecraft:the_end"
    ]
#if os(WASI)
    // A custom actor executor must be available without actor isolation. Leaving this stored
    // property isolated can cause a synchronous actor entry (such as `loot`) to trip Swift's
    // executor precondition after an async hop from a JavaScript event callback.
    private nonisolated let serialExecutor: TileGenerationExecutor
    private let samplingBackend: TileSamplingBackend
    private let overworldDimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private let tileSize = 256
    private var dataPack: DataPack?
    private var currentSeed: WorldSeed?
    private var currentDimensionID: String?
    private var generator: WorldGenerator?
    private var usesNativeBulkSampler = false
    private var densityCompilationMilliseconds: Double?
    private var densityCompilationBackend: String?
    private var wasmRuntime: BrowserWASMRuntime?
    private var samplers: [TileSamplerKey: ReusableBiomeTileSampler] = [:]
    private var structureSampler: StructurePlacementSampler?
    private var structureSetDescriptors: [StructureSetDescriptor] = []
    private var validatedStructureStarts: [StructureValidationKey: String] = [:]
    private var rejectedStructureStarts: Set<StructureValidationKey> = []
    private var randomStructurePlacements: [RandomStructureRegionKey: StructurePlacementSample] = [:]
    private var emptyRandomStructureRegions: Set<RandomStructureRegionKey> = []
    private var concentricStructurePlacements: [String: [StructurePlacementSample]] = [:]
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
    private let tileSize = 256
    private var dataPack: DataPack?
    private var currentSeed: WorldSeed?
    private var currentDimensionID: String?
    private var generator: WorldGenerator?
    private var usesNativeBulkSampler = false
    private var densityCompilationMilliseconds: Double?
    private var densityCompilationBackend: String?
    private var samplers: [TileSamplerKey: ReusableBiomeTileSampler] = [:]
    private var structureSampler: StructurePlacementSampler?
    private var structureSetDescriptors: [StructureSetDescriptor] = []
    private var validatedStructureStarts: [StructureValidationKey: String] = [:]
    private var rejectedStructureStarts: Set<StructureValidationKey> = []
    private var randomStructurePlacements: [RandomStructureRegionKey: StructurePlacementSample] = [:]
    private var emptyRandomStructureRegions: Set<RandomStructureRegionKey> = []
    private var concentricStructurePlacements: [String: [StructurePlacementSample]] = [:]
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
        resetForDatapackReload()
        let rootURL = try materialize(bundle: bundle)
        dataPackRoot = rootURL
        dataPack = try DataPack(
            fromRootPath: rootURL,
            loadingOptions: []
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

    func initialize(rootURL: URL, decodingVersion: Version? = nil) throws {
        resetForDatapackReload()
        dataPackRoot = rootURL
        dataPack = try DataPack(
            fromRootPath: rootURL,
            loadingOptions: [],
            decodingVersion: decodingVersion
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
        try configureGenerator(for: 0, dimensionID: "minecraft:overworld", using: dataPack)
        guard let generator, usesNativeBulkSampler || samplingBackend == .nestedWASM else { return }
        let strategy: CompilationBackend = samplingBackend == .nestedWASM ? .wasm : .llvm
        for exponent in -3...8 {
            let blocksPerPixel = pow(2.0, Double(exponent))
            let tileSpan = max(1, Int32((Double(tileSize) * blocksPerPixel).rounded()))
            let sampleScale = max(1, Int32((Double(tileSpan) / 128.0).rounded()))
            let sampleWidth = max(1, Int((tileSpan + sampleScale - 1) / sampleScale))
            let key = TileSamplerKey(
                dimensionID: "minecraft:overworld",
                sampleWidth: Int32(sampleWidth), sampleHeight: Int32(sampleWidth), sampleYCount: 1,
                sampleScale: sampleScale, sampleYStep: 1
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
        // Structure validation asks for exact quart-aligned positions after resolving terrain
        // height. Precompile that tiny shape so the first structure does not invoke the compiler.
        _ = try compiledBiomeSampler(
            using: generator,
            dimensionID: "minecraft:overworld",
            sampleWidth: 1,
            sampleHeight: 1,
            sampleYCount: 1,
            sampleScale: 4,
            sampleYStep: 4,
            strategy: strategy
        )
        // Force DPReader's cached full-chunk terrain program as well. Structure-start heightmap
        // validation shares this program, so otherwise its first candidate pays the compile cost.
        let warmupChunk = ProtoChunk()
        try generator.generateInto(warmupChunk, at: PosInt2D(x: 0, z: 0))
    }

    func registryIDs() -> (biomes: [String], dimensions: [String], structures: [String]) {
        guard let dataPack else { return ([], [], []) }
        return (
            dataPack.biomeRegistry.entries().map(\.key.name).sorted(),
            loadedDimensionIDs(in: dataPack),
            dataPack.structureSetRegistry.entries().map(\.key.name).sorted()
        )
    }

    func browserRegistryMetadata() -> BrowserRegistryMetadata {
        BrowserRegistryMetadata(
            biomeIDs: dataPack?.biomeRegistry.entries().map(\.key.name).sorted() ?? [],
            dimensionIDs: dataPack.map(loadedDimensionIDs(in:)) ?? [],
            structureSets: structureSetDescriptors
                .map {
                    BrowserStructureSetMetadata(
                        id: $0.keyName,
                        spacing: $0.spacing,
                        hasFrequency: $0.frequency != nil,
                        structureIDs: $0.structureIDs
                    )
                }
                .sorted { $0.id < $1.id }
        )
    }

    private func loadedDimensionIDs(in dataPack: DataPack) -> [String] {
        Self.vanillaDimensionIDs
            .union(dataPack.dimensionsRegistry.entries().map(\.key.name))
            .sorted()
    }

    /// Generate the paintable part of a tile. Browser callers use this entry point so structure
    /// discovery cannot delay the first pixels; native callers continue through `generate`.
    func generateBiomeTile(_ job: PendingTileJob) throws -> GeneratedTile {
        guard let dataPack else {
            throw BrowserAppError.message("Tile generation worker is not ready.")
        }

        let start = Date()
        try configureGenerator(for: job.seed, dimensionID: job.dimensionID, using: dataPack)
        try Task.checkCancellation()

        let generated = try makeTile(
            using: generator!,
            blocksPerPixel: job.tileBlocksPerPixel,
            tileX: job.tileX,
            tileZ: job.tileZ,
            sampleY: job.sampleY,
            dimensionID: job.dimensionID
        )
        try Task.checkCancellation()
        return GeneratedTile(
            tile: generated.tile,
            biomeCache: generated.biomeCache,
            generationMilliseconds: Date().timeIntervalSince(start) * 1_000.0,
            densityCompilationMilliseconds: densityCompilationMilliseconds,
            densityCompilationBackend: densityCompilationBackend
        )
    }

    func generate(_ job: PendingTileJob) throws -> GeneratedTile {
        let start = Date()
        let generated = try generateBiomeTile(job)
        guard let biomeCache = generated.biomeCache else { return generated }
        let structures = try generateStructures(for: job, biomeCache: biomeCache)
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
            biomeCache: nil,
            generationMilliseconds: Date().timeIntervalSince(start) * 1_000.0,
            densityCompilationMilliseconds: generated.densityCompilationMilliseconds,
            densityCompilationBackend: generated.densityCompilationBackend
        )
    }

    func generateStructures(
        for job: PendingTileJob,
        biomeCache: TileBiomeCache
    ) throws -> StructureQueryResult? {
        try Task.checkCancellation()
        let structureQuery = StructureQuery(
            seed: job.seed,
            dimensionID: job.dimensionID,
            minX: biomeCache.usableMinX,
            maxX: biomeCache.usableMaxX,
            minZ: biomeCache.usableMinZ,
            maxZ: biomeCache.usableMaxZ,
            enabledStructureSets: job.enabledStructureSets ?? Set(structureSetDescriptors.map(\.keyName)),
            minimumSpacingBlocks: Double(tileSize) * job.tileBlocksPerPixel / 8.0
        )
        guard !structureQuery.enabledStructureSets.isEmpty else { return nil }
        return try structures(
            in: structureQuery,
            biomeSampler: biomeCache.biome(at:)
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
            dimensionID: request.dimensionID,
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

    func searchLoot(_ query: LootSearchQuery, seed: Int64) async throws -> [MapLootPresentation] {
        try await searchLoot(query, seed: seed, onProgress: { _ in })
    }

    func searchLoot(
        _ query: LootSearchQuery,
        seed: Int64,
        onProgress: @escaping @Sendable (LootSearchProgress) -> Void
    ) async throws -> [MapLootPresentation] {
        guard query.radius > 0 else {
            throw BrowserAppError.message("Radius must be greater than zero.")
        }
        guard query.radius <= 10_000 else {
            throw BrowserAppError.message("Radius is limited to 10,000 blocks.")
        }
        let itemQuery = query.itemQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemQuery.isEmpty else {
            throw BrowserAppError.message("Enter an item, enchantment, potion, or effect to search for.")
        }
        guard let dataPack else {
            throw BrowserAppError.message("Structure generation worker is not ready.")
        }
        let worldSeed = UInt64(bitPattern: seed)
        try configureGenerator(for: worldSeed, dimensionID: "minecraft:overworld", using: dataPack)
        guard let generator else { throw BrowserAppError.message("Structure generation worker is not ready.") }
        let minimum = -query.radius
        let maximum = query.radius
        let minX = query.startX &+ minimum
        let maxX = query.startX &+ maximum
        let minZ = query.startZ &+ minimum
        let maxZ = query.startZ &+ maximum
        let structures = try structures(
            in: StructureQuery(
                seed: worldSeed,
                dimensionID: "minecraft:overworld",
                minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ,
                enabledStructureSets: Set(structureSetDescriptors.map(\.keyName)),
                minimumSpacingBlocks: 0
            ),
            biomeSampler: { position in
                try generator.sampleBiome(at: position, in: self.dimensionKey(for: "minecraft:overworld"))
            }
        )?.points ?? []
        var matches: [MapLootPresentation] = []
        for (index, structure) in structures.enumerated() {
            try Task.checkCancellation()
            let presentation = MapStructurePresentation(
                setID: structure.setID, structureID: structure.structureID, x: structure.x, z: structure.z
            )
            onProgress(LootSearchProgress(
                structuresScanned: index, totalStructures: structures.count, currentStructure: presentation
            ))
            let newMatches: [MapLootPresentation] = try loot(for: structure, seed: worldSeed).compactMap { container -> MapLootPresentation? in
                guard container.loot.contains(where: { LootSearchMatcher.matches(item: $0, query: itemQuery) }) else {
                    return nil
                }
                return MapLootPresentation(
                    block: container.block, lootTable: container.lootTable,
                    x: container.x, y: container.y, z: container.z, items: container.loot
                )
            }
            matches.append(contentsOf: newMatches)
            onProgress(LootSearchProgress(
                structuresScanned: index + 1, totalStructures: structures.count,
                currentStructure: presentation, matches: newMatches
            ))
        }
        return matches.sorted { ($0.z, $0.x, $0.y, $0.block) < ($1.z, $1.x, $1.y, $1.block) }
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
        try configureGenerator(for: query.seed, dimensionID: query.dimensionID, using: dataPack)
        guard let generator, let structureSampler else { return nil }
        let validationContext = try makeValidationContext(
            using: generator,
            dimensionID: query.dimensionID,
            biomeSampler: biomeSampler
        )

        var points = Set<StructurePoint>()
        for descriptor in structureSetDescriptors where query.enabledStructureSets.contains(descriptor.keyName) {
            try Task.checkCancellation()
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
                    try Task.checkCancellation()
                    for regionX in minRegionX...maxRegionX {
                        let cacheKey = RandomStructureRegionKey(
                            setID: descriptor.keyName,
                            regionX: regionX,
                            regionZ: regionZ
                        )
                        if let sample = randomStructurePlacements[cacheKey] {
                            generated.append(sample)
                            metrics.candidates += 1
                        } else if !emptyRandomStructureRegions.contains(cacheKey) {
                            if let sample = try structureSampler.sampleStructureSet(
                                inRegion: PosInt2D(x: regionX, z: regionZ),
                                for: RegistryKey(referencing: descriptor.keyName)
                            ) {
                                randomStructurePlacements[cacheKey] = sample
                                generated.append(sample)
                                metrics.candidates += 1
                            } else {
                                emptyRandomStructureRegions.insert(cacheKey)
                            }
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
                if let cached = concentricStructurePlacements[descriptor.keyName] {
                    samples = cached
                } else {
                    let generated = try structureSampler.sampleAllPlacements(
                        for: RegistryKey(referencing: descriptor.keyName)
                    )
                    concentricStructurePlacements[descriptor.keyName] = generated
                    samples = generated
                }
                metrics.samplingMilliseconds += Date().timeIntervalSince(samplingStart) * 1_000.0
                metrics.candidates += samples.count
            }

            let validationStart = Date()
            for sample in samples where pointIsVisible(sample.blockPos, in: query) {
                try Task.checkCancellation()
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
                let validationKey = StructureValidationKey(
                    setID: descriptor.keyName,
                    chunkX: sample.chunkPos.x,
                    chunkZ: sample.chunkPos.z
                )
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
        try configureGenerator(for: query.seed, dimensionID: query.dimensionID, using: dataPack)
        guard let generator, let structureSampler else { return nil }
        let validationContext = try makeValidationContext(
            using: generator,
            dimensionID: query.dimensionID,
            biomeSampler: biomeSampler
        )

        var points = Set<StructurePoint>()
        for descriptor in structureSetDescriptors
        where descriptor.kind == .concentricRings && query.enabledStructureSets.contains(descriptor.keyName) {
            let samplingStart = Date()
            let samples: [StructurePlacementSample]
            if let cached = concentricStructurePlacements[descriptor.keyName] {
                samples = cached
            } else {
                let generated = try structureSampler.sampleAllPlacements(
                    for: RegistryKey(referencing: descriptor.keyName)
                )
                concentricStructurePlacements[descriptor.keyName] = generated
                samples = generated
            }
            metrics.samplingMilliseconds += Date().timeIntervalSince(samplingStart) * 1_000.0
            metrics.candidates += samples.count
            let validationStart = Date()
            for sample in samples where pointIsVisible(sample.blockPos, in: query) {
                let validationKey = StructureValidationKey(
                    setID: descriptor.keyName,
                    chunkX: sample.chunkPos.x,
                    chunkZ: sample.chunkPos.z
                )
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
        let startChunk = PosInt2D(x: floorDivide(structure.x, by: 16), z: floorDivide(structure.z, by: 16))
        var terrainChunks: [String: ProtoChunk] = [:]
        // Every structure receives the same lazy terrain provider. Most structures never ask
        // for a block, so they do not cause any terrain chunks to be generated. Those that do
        // (for example pyramids, jigsaw pieces, and mineshaft minecarts) populate this cache on
        // demand, one chunk at a time.
        try configureGenerator(for: seed, dimensionID: "minecraft:overworld", using: dataPack)
        guard let terrainGenerator = generator else {
            throw BrowserAppError.message("Structure generation worker is not ready.")
        }

        let air = BlockState(id: "minecraft:air")
        let context = StructureGenerationContext(
            seaLevel: 63,
            minimumWorldY: -64,
            usingDataPacks: [dataPack],
            blockSampler: { position in
                let chunkX = floorDivide(position.x, by: 16)
                let chunkZ = floorDivide(position.z, by: 16)
                let coordinate = "\(chunkX),\(chunkZ)"
                if terrainChunks[coordinate] == nil {
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
        let generatedContainers = try definition.generateLoot(
            worldSeed: seed,
            startChunk: startChunk,
            context: context
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
                decoder: dataPack.makeDecoder(),
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
        decoder: JSONDecoder,
        enchantmentResources: LootEnchantmentResources
    ) throws -> [String] {
        func loadLootTable(_ identifier: String) throws -> LootTable {
            let parts = identifier.split(separator: ":", maxSplits: 1)
            let namespace = parts.count == 2 ? String(parts[0]) : "minecraft"
            let path = parts.count == 2 ? String(parts[1]) : identifier
            let tableURL = rootURL.appendingPathComponent("data/\(namespace)/loot_table/\(path).json")
            return try decoder.decode(LootTable.self, from: Data(contentsOf: tableURL))
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
                metadata.append("Potion: \(potion) (\(titleCaseID(potion)))")
            }

            if case .array(let effects)? = components["minecraft:suspicious_stew_effects"] {
                let descriptions = effects.compactMap { effect -> String? in
                    guard case .object(let values) = effect,
                          let id = stringValue(values["id"]) else { return nil }
                    if let duration = integerValue(values["duration"]) {
                        return "\(id) (\(titleCaseID(id)), \(duration) ticks)"
                    }
                    return "\(id) (\(titleCaseID(id)))"
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

    private func configureGenerator(for seed: WorldSeed, dimensionID: String, using dataPack: DataPack) throws {
        if currentDimensionID != dimensionID {
            generator = nil
            currentSeed = nil
            currentDimensionID = dimensionID
            samplers.removeAll(keepingCapacity: true)
            structureSampler = nil
            validatedStructureStarts.removeAll(keepingCapacity: true)
            rejectedStructureStarts.removeAll(keepingCapacity: true)
            randomStructurePlacements.removeAll(keepingCapacity: true)
            emptyRandomStructureRegions.removeAll(keepingCapacity: true)
            concentricStructurePlacements.removeAll(keepingCapacity: true)
            structureHeightmapSampler = nil
#if os(WASI)
            wasmRuntime?.invalidate()
            wasmRuntime = nil
#endif
        }
        let noiseSettings = RegistryKey<NoiseSettings>(referencing: noiseSettingsID(for: dimensionID))
        if let generator {
            if currentSeed != seed {
                // DPReader retains compiled graphs and search trees across seed changes.
                try generator.setWorldSeed(seed)
                currentSeed = seed
                // Bulk samplers are also seed-stable compiled programs.  Their retained
                // instances are updated by setWorldSeed; throwing them away here defeats the
                // startup prewarm and makes the first tile for every new window pay compilation
                // again.
                structureSampler = StructurePlacementSampler(withWorldSeed: seed, usingDataPacks: [dataPack])
                validatedStructureStarts.removeAll(keepingCapacity: true)
                rejectedStructureStarts.removeAll(keepingCapacity: true)
                randomStructurePlacements.removeAll(keepingCapacity: true)
                emptyRandomStructureRegions.removeAll(keepingCapacity: true)
                concentricStructurePlacements.removeAll(keepingCapacity: true)
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
                        usingSettings: noiseSettings,
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
                            usingSettings: noiseSettings,
                            compilationBackend: .llvm
                        )
                        usesNativeBulkSampler = true
                        densityCompilationBackend = "LLVM"
                    } catch {
                        generator = try WorldGenerator(
                            withWorldSeed: seed,
                            usingDataPacks: [dataPack],
                            usingSettings: noiseSettings
                        )
                        usesNativeBulkSampler = false
                    }
                } else {
                    generator = try WorldGenerator(
                        withWorldSeed: seed,
                        usingDataPacks: [dataPack],
                        usingSettings: noiseSettings
                    )
                    usesNativeBulkSampler = false
                }
#else
                generator = try WorldGenerator(
                    withWorldSeed: seed,
                    usingDataPacks: [dataPack],
                    usingSettings: noiseSettings
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
            randomStructurePlacements.removeAll(keepingCapacity: true)
            emptyRandomStructureRegions.removeAll(keepingCapacity: true)
            concentricStructurePlacements.removeAll(keepingCapacity: true)
            structureHeightmapSampler = nil
        }
    }

    private func dimensionKey(for dimensionID: String) -> RegistryKey<DPReader.Dimension> {
        // DPReader names the vanilla Nether biome tree `minecraft:nether`, while the vanilla
        // world preset (and therefore the UI) identifies the dimension as `minecraft:the_nether`.
        let generatorID = dimensionID == "minecraft:the_nether" ? "minecraft:nether" : dimensionID
        return RegistryKey(referencing: generatorID)
    }

    private func noiseSettingsID(for dimensionID: String) -> String {
        switch dimensionID {
        case "minecraft:the_nether", "minecraft:nether":
            return "minecraft:nether"
        case "minecraft:the_end", "minecraft:end":
            return "minecraft:end"
        default:
            return "minecraft:overworld"
        }
    }

    private func pointIsVisible(_ point: PosInt2D, in query: StructureQuery) -> Bool {
        point.x >= query.minX && point.x <= query.maxX
            && point.z >= query.minZ && point.z <= query.maxZ
    }

    private func makeValidationContext(
        using generator: WorldGenerator,
        dimensionID: String,
        biomeSampler: @escaping (PosInt3D) throws -> RegistryKey<Biome>?
    ) throws -> StructureStartValidationContext {
        let dimension = dimensionKey(for: dimensionID)
        let terrain: GeneratedStructureHeightmapSampler
        if let existing = structureHeightmapSampler {
            terrain = existing
        } else {
            terrain = GeneratedStructureHeightmapSampler(
                worldGenerator: generator,
                seaLevel: 63,
                minimumWorldY: -64,
                maximumWorldY: 319,
                dimension: dimension
            )
            structureHeightmapSampler = terrain
        }
        return StructureStartValidationContext(
            dimension: dimension,
            seaLevel: 63,
            minimumWorldY: -64,
            maximumWorldY: 319,
            heightmapSampler: terrain.height,
            biomeSampler: biomeSampler
        )
    }

    private func compiledBiomeSampler(
        using generator: WorldGenerator,
        dimensionID: String,
        sampleWidth: Int32,
        sampleHeight: Int32,
        sampleYCount: Int32 = 1,
        sampleScale: Int32,
        sampleYStep: Int32 = 1,
        strategy: CompilationBackend
    ) throws -> ReusableBiomeTileSampler {
        // The key includes both fixed shape and stride, matching DPReader's retained-sampler
        // contract. The associated output buffer is reused for every subsequent tile.
        let key = TileSamplerKey(
            dimensionID: dimensionID,
            sampleWidth: sampleWidth,
            sampleHeight: sampleHeight,
            sampleYCount: sampleYCount,
            sampleScale: sampleScale,
            sampleYStep: sampleYStep
        )
        let sampler: ReusableBiomeTileSampler
        if let existing = samplers[key] {
            sampler = existing
        } else {
            let compiled = try generator.makeBiomeIDBulkSampler(
                for: CompiledDensityFunctionBufferContext(
                    xCount: sampleWidth, yCount: sampleYCount, zCount: sampleHeight,
                    xStep: sampleScale, yStep: sampleYStep, zStep: sampleScale
                ),
                in: dimensionKey(for: dimensionID),
                strategy: strategy
            )
            sampler = ReusableBiomeTileSampler(sampler: compiled)
            samplers[key] = sampler
        }
        return sampler
    }

    private func compiledBiomeNames(
        using generator: WorldGenerator,
        dimensionID: String,
        sampleWidth: Int32,
        sampleHeight: Int32,
        sampleYCount: Int32 = 1,
        sampleScale: Int32,
        sampleYStep: Int32 = 1,
        at position: PosInt3D,
        strategy: CompilationBackend
    ) throws -> [String] {
        try compiledBiomeSampler(
            using: generator,
            dimensionID: dimensionID,
            sampleWidth: sampleWidth,
            sampleHeight: sampleHeight,
            sampleYCount: sampleYCount,
            sampleScale: sampleScale,
            sampleYStep: sampleYStep,
            strategy: strategy
        ).biomeNames(at: position)
    }

    private func makeTile(
        using generator: WorldGenerator,
        blocksPerPixel: Double,
        tileX: Int,
        tileZ: Int,
        sampleY: Int32,
        dimensionID: String
    ) throws -> (tile: CachedTile, biomeCache: TileBiomeCache) {
        // Keep the normal map path at a fixed 128-by-128 output shape. The level of detail lives
        // in the sampling stride, which lets one fused bulk program serve every tile at a scale.
        // At sub-quarter-block zoom a stride below one is impossible, so retain exact pixels.
        let tileSpan = max(1, Int32((Double(tileSize) * blocksPerPixel).rounded()))
        let sampleScale = max(1, Int32((Double(tileSpan) / 128.0).rounded()))
        let sampleWidth = max(1, Int((tileSpan + sampleScale - 1) / sampleScale))
        let startX = Int32(tileX) &* tileSpan
        let startZ = Int32(tileZ) &* tileSpan
        let palette: [String]
        let indices: [UInt16]
        switch samplingBackend {
        case .nestedWASM:
            (palette, indices) = try compiledBiomeSampler(
                using: generator,
                dimensionID: dimensionID,
                sampleWidth: Int32(sampleWidth),
                sampleHeight: Int32(sampleWidth),
                sampleScale: sampleScale,
                strategy: .wasm
            ).tile(at: PosInt3D(x: startX, y: sampleY, z: startZ))
        case .scalar:
            if usesNativeBulkSampler {
                (palette, indices) = try compiledBiomeSampler(
                    using: generator,
                    dimensionID: dimensionID,
                    sampleWidth: Int32(sampleWidth),
                    sampleHeight: Int32(sampleWidth),
                    sampleScale: sampleScale,
                    strategy: .llvm
                ).tile(at: PosInt3D(x: startX, y: sampleY, z: startZ))
            } else {
                let extent = Int32(sampleWidth) * sampleScale
                guard let biomes = try generator.generateBiomesInSquare(
                    from: PosInt2D(x: startX, z: startZ),
                    to: PosInt2D(x: startX + extent, z: startZ + extent),
                    atY: sampleY,
                    in: dimensionKey(for: dimensionID),
                    scale: sampleScale,
                    forceNoBaking: sampleScale == 1
                ) else {
                    throw BrowserAppError.message("The overworld biome sampler returned no data.")
                }
                var scalarPalette = ["minecraft:plains"]
                var paletteIndices = ["minecraft:plains": UInt16(0)]
                var scalarIndices = [UInt16](repeating: 0, count: biomes.count)
                for (index, biome) in biomes.enumerated() {
                    let biomeID = biome.name
                    let paletteIndex = paletteIndices[biomeID] ?? UInt16(scalarPalette.count)
                    if paletteIndices[biomeID] == nil {
                        guard scalarPalette.count <= Int(UInt16.max) else {
                            throw BrowserAppError.message("A tile contains too many biome types.")
                        }
                        scalarPalette.append(biomeID)
                        paletteIndices[biomeID] = paletteIndex
                    }
                    scalarIndices[index] = paletteIndex
                }
                palette = scalarPalette
                indices = scalarIndices
            }
        }

        // Structure validation is quart-aligned and may inspect a 29-block radius around an
        // ocean monument. Generate a padded quart grid in the same biome pass so validation can
        // read the results without asking WorldGenerator to sample individual positions again.
        let structureScale: Int32 = 4
        let structureMinY: Int32 = -64
        let structureYCount: Int32 = 96
        let structureMargin: Int32 = 32
        // Exact-position caching avoids sampling 96 vertical biomes when validation only needs
        // the biome at its already-resolved generation height.
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
        ) { [self] position in
            switch samplingBackend {
            case .nestedWASM:
                guard let biome = try compiledBiomeNames(using: generator, dimensionID: dimensionID, sampleWidth: 1, sampleHeight: 1, sampleYCount: 1, sampleScale: structureScale, sampleYStep: 4, at: position, strategy: .wasm).first else {
                    throw BrowserAppError.message("The dimension structure biome sampler returned no data.")
                }
                return biome
            case .scalar where usesNativeBulkSampler:
                guard let biome = try compiledBiomeNames(using: generator, dimensionID: dimensionID, sampleWidth: 1, sampleHeight: 1, sampleScale: structureScale, sampleYStep: 4, at: position, strategy: .llvm).first else {
                    throw BrowserAppError.message("The dimension structure biome sampler returned no data.")
                }
                return biome
            case .scalar:
                guard let biome = try generator.sampleBiome(at: position, in: dimensionKey(for: dimensionID)) else {
                    throw BrowserAppError.message("The dimension structure biome sampler returned no data.")
                }
                return biome.name
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
        let identifier = bundle.id ?? "default"
        guard !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else {
            throw BrowserAppError.message("Datapack bundle has an invalid identifier.")
        }
        let rootURL = URL(fileURLWithPath: runtimeDatapackPath, isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
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

    /// A newly selected version must never reuse a generator or sampler compiled against the
    /// previous pack. The browser keeps each materialised pack in its own directory so an older
    /// in-flight loot read cannot observe replacement files.
    private func resetForDatapackReload() {
        dataPack = nil
        currentSeed = nil
        currentDimensionID = nil
        generator = nil
        usesNativeBulkSampler = false
        densityCompilationMilliseconds = nil
        densityCompilationBackend = nil
        samplers.removeAll(keepingCapacity: true)
        structureSampler = nil
        structureSetDescriptors.removeAll(keepingCapacity: true)
        validatedStructureStarts.removeAll(keepingCapacity: true)
        rejectedStructureStarts.removeAll(keepingCapacity: true)
        randomStructurePlacements.removeAll(keepingCapacity: true)
        emptyRandomStructureRegions.removeAll(keepingCapacity: true)
        concentricStructurePlacements.removeAll(keepingCapacity: true)
        structureHeightmapSampler = nil
        dataPackRoot = nil
#if os(WASI)
        wasmRuntime?.invalidate()
        wasmRuntime = nil
#endif
    }

}
