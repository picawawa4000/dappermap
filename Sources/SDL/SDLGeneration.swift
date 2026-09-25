import DapperMapCore
import DapperMapEngine
import DPReader
import Foundation
import SDL2

extension SDLMapApplication {
    func requestRegenerate() {
        generationTask?.cancel()
        hasRendered = true
        renderGeneration &+= 1
        let generation = renderGeneration
        let datapack = selectedDatapack
        status = "Preparing world generator…"
        let root: URL
        do { root = try datapackRoot(for: datapack) }
        catch {
            status = "Minecraft \(datapack.version) datapack not found"
            return
        }
        let tileBPP = MapMath.tileBlocksPerPixel(for: blocksPerPixel)
        let span = Double(MapMath.tileSize) * tileBPP
        let worldStartX = centerX - Double(mapWidth) * blocksPerPixel / 2
        let worldStartZ = centerZ - Double(mapHeight) * blocksPerPixel / 2
        let minTileX = Int(floor(worldStartX / span))
        let maxTileX = Int(floor((worldStartX + Double(mapWidth) * blocksPerPixel - 0.0001) / span))
        let minTileZ = Int(floor(worldStartZ / span))
        let maxTileZ = Int(floor((worldStartZ + Double(mapHeight) * blocksPerPixel - 0.0001) / span))
        let centerTileX = Int(floor(centerX / span))
        let centerTileZ = Int(floor(centerZ / span))
        let requests: [MapTileRequest] = MapMath.centerFirstTileCoordinates(
            minTileX: minTileX,
            maxTileX: maxTileX,
            minTileZ: minTileZ,
            maxTileZ: maxTileZ,
            centerTileX: centerTileX,
            centerTileZ: centerTileZ
        ).compactMap { tileX, tileZ -> MapTileRequest? in
                let key = SDLTileKey(
                    seed: seed, sampleY: sampleY, scaleKey: MapMath.scaleKey(for: tileBPP),
                    tileX: tileX, tileZ: tileZ
                )
                if let cached = tiles[key], enabledStructureSets.isEmpty || cached.structuresComplete {
                    return nil
                }
                return MapTileRequest(generation: generation, seed: seed, centerX: centerX, centerZ: centerZ,
                    blocksPerPixel: blocksPerPixel, viewportWidth: mapWidth, viewportHeight: mapHeight,
                    tileBlocksPerPixel: tileBPP, tileX: tileX, tileZ: tileZ, sampleY: sampleY,
                    enabledStructureSets: nil)
        }
        pendingTileCount = requests.count
        biomeGenerationStatus = requests.isEmpty
            ? "Biomes: ready from cache."
            : "Biomes: 0/\(requests.count) ready."
        structureGenerationStatus = enabledStructureSets.isEmpty
            ? "Structures: disabled."
            : (requests.isEmpty
                ? "Structures: ready from cache."
                : "Structures: 0/\(requests.count) ready.")
        let workers = threadCount
        let platform: NativeGenerationPlatform
        if let cached = generationPlatform,
           generationPlatformThreadCount == workers,
           generationPlatformLootSearchThreadCount == lootSearchThreadCount,
           generationPlatformUsesLLVM == enableDensityCompilation,
           generationPlatformRoot == root,
           generationPlatformPackFormat == datapack.packFormat {
            platform = cached
        } else {
            platform = NativeGenerationPlatform(
                threadCount: workers,
                lootSearchThreadCount: lootSearchThreadCount,
                enableDensityCompilation: enableDensityCompilation
            )
            platformReady = false
            generationPlatform = platform
            generationPlatformThreadCount = workers
            generationPlatformLootSearchThreadCount = lootSearchThreadCount
            generationPlatformUsesLLVM = enableDensityCompilation
            generationPlatformRoot = root
            generationPlatformPackFormat = datapack.packFormat
        }
        let results = generationResults
        let startedAt = Date()
        let tileGenerationMode = tileGenerationMode
        generationTask = Task.detached {
            do {
                results.store(.progress(generation: generation, message: "Preparing world generator…", elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                try await platform.initialize(rootURL: root, packFormat: datapack.packFormat)
                let registry = await platform.registryIDs()
                try Task.checkCancellation()
                results.store(.registry(generation: generation, biomes: registry.biomes, structures: registry.structures))
                results.store(.progress(generation: generation, message: "Generating centre tiles first…", elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                if tileGenerationMode == .combined {
                    try await withThrowingTaskGroup(of: MapTilePresentation.self) { group in
                    var nextRequest = 0
                    for _ in 0..<min(workers, requests.count) {
                        let request = requests[nextRequest]
                        nextRequest += 1
                        group.addTask {
                            try await platform.generateTile(request) {
                                results.store(.strongholds(generation: generation))
                            }
                        }
                    }
                    var completed = 0
                    for try await tile in group {
                        try Task.checkCancellation()
                        if nextRequest < requests.count {
                            let request = requests[nextRequest]
                            nextRequest += 1
                            group.addTask {
                                try await platform.generateTile(request) {
                                    results.store(.strongholds(generation: generation))
                                }
                            }
                        }
                        completed += 1
                        results.store(.tile(
                            generation: generation,
                            tile: tile,
                            completed: completed,
                            total: requests.count,
                            elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000
                        ))
                    }
                    }
                } else {
                    await withTaskGroup(of: SDLTileWorkResult.self) { group in
                        for request in requests {
                            group.addTask {
                                do { return .biome(.success(try await platform.generateBiomeTile(request))) }
                                catch { return .biome(.failure(error)) }
                            }
                            // `nil` deliberately means the service's default set selection, not
                            // "no structures". SDL uses it while its registry is loading.
                            if tileGenerationMode == .parallelStructures, request.enabledStructureSets?.isEmpty != true {
                                group.addTask {
                                    do {
                                        return .structures(.success(try await platform.generateStructures(for: request) {
                                            results.store(.strongholds(generation: generation))
                                        }))
                                    }
                                    catch { return .structures(.failure(error)) }
                                }
                            }
                        }
                        var completedBiomes = 0
                        var completedStructures = 0
                        for await result in group {
                            switch result {
                            case .biome(.success(let tile)):
                                completedBiomes += 1
                                results.store(.biomeTile(generation: generation, tile: tile, completed: completedBiomes, total: requests.count, elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                                if tileGenerationMode == .deferredStructures,
                                   requests.first(where: { $0.tileX == tile.tileX && $0.tileZ == tile.tileZ })?.enabledStructureSets?.isEmpty != true,
                                   let request = requests.first(where: { $0.tileX == tile.tileX && $0.tileZ == tile.tileZ }) {
                                    group.addTask {
                                        do {
                                            return .structures(.success(try await platform.generateStructures(for: request) {
                                                results.store(.strongholds(generation: generation))
                                            }))
                                        }
                                        catch { return .structures(.failure(error)) }
                                    }
                                }
                            case .structures(.success(let structures)):
                                completedStructures += 1
                                results.store(.tileStructures(generation: generation, structures: structures, completed: completedStructures, total: requests.count, elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                            case .biome(.failure(let error)), .structures(.failure(let error)):
                                results.store(.failure(generation: generation, message: "Generation failed: \(error)"))
                            }
                        }
                    }
                }
                results.store(.finished(generation: generation, elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
            } catch is CancellationError {
            } catch {
                results.store(.failure(generation: generation, message: "Generation failed: \(error)"))
            }
        }
    }

    func installCompletedGeneration(renderer: OpaquePointer) {
        while let result = generationResults.take() {
            switch result {
            case let .registry(generation, biomes, structures) where generation == renderGeneration:
                platformReady = true
                enabledStructureSets.formUnion(Set(structures).subtracting(loadedStructureIDs))
                loadedBiomeIDs = biomes
                loadedStructureIDs = structures
            case let .progress(generation, message, elapsedMilliseconds) where generation == renderGeneration:
                status = "\(message) Setup \(formatDuration(elapsedMilliseconds))."
            case let .strongholds(generation) where generation == renderGeneration:
                structureGenerationStatus = "Generating strongholds…"
            case let .tile(generation, generatedTile, completed, total, elapsedMilliseconds) where generation == renderGeneration:
                let key = SDLTileKey(seed: generatedTile.seed, sampleY: sampleY, scaleKey: generatedTile.scaleKey, tileX: generatedTile.tileX, tileZ: generatedTile.tileZ)
                tiles[key] = generatedTile
                structureMarkerTileRevision &+= 1
                tileRecencyClock &+= 1
                tileRecency[key] = tileRecencyClock
                installTexture(for: generatedTile, key: key, renderer: renderer)
                evictTileCacheIfNeeded()
                tile = generatedTile
                pendingTileCount = max(0, total - completed)
                biomeGenerationStatus = "Biomes: \(completed)/\(total) ready."
                structureGenerationStatus = enabledStructureSets.isEmpty
                    ? "Structures: disabled."
                    : "Structures: \(completed)/\(total) ready."
                let compilation = generatedTile.densityCompilationMilliseconds.flatMap { milliseconds in
                    generatedTile.densityCompilationBackend.map { " \($0) compile \(formatDuration(milliseconds))." }
                } ?? ""
                status = "\(completed)/\(total) tiles. View \(formatDuration(elapsedMilliseconds)); tile \(formatDuration(generatedTile.generationMilliseconds)).\(compilation)"
            case let .biomeTile(generation, generatedTile, completed, total, elapsedMilliseconds) where generation == renderGeneration:
                let key = SDLTileKey(seed: generatedTile.seed, sampleY: sampleY, scaleKey: generatedTile.scaleKey, tileX: generatedTile.tileX, tileZ: generatedTile.tileZ)
                tiles[key] = generatedTile
                structureMarkerTileRevision &+= 1
                tileRecencyClock &+= 1
                tileRecency[key] = tileRecencyClock
                installTexture(for: generatedTile, key: key, renderer: renderer)
                evictTileCacheIfNeeded()
                tile = generatedTile
                pendingTileCount = max(0, total - completed)
                biomeGenerationStatus = "Biomes: \(completed)/\(total) ready."
                structureGenerationStatus = enabledStructureSets.isEmpty ? "Structures: disabled." : structureGenerationStatus
                status = "\(completed)/\(total) biome tiles. View \(formatDuration(elapsedMilliseconds)); tile \(formatDuration(generatedTile.generationMilliseconds))."
                if let structures = deferredStructureResults.removeValue(forKey: key) {
                    install(structures: structures)
                }
            case let .tileStructures(generation, structures, completed, total, _) where generation == renderGeneration:
                install(structures: structures)
                structureGenerationStatus = "Structures: \(completed)/\(total) ready."
            case let .finished(generation, elapsedMilliseconds) where generation == renderGeneration:
                pendingTileCount = 0
                status = "Rendered \(formatDuration(elapsedMilliseconds)) total."
            case let .loot(request, containers, message) where request == lootRequest:
                loot = containers
                lootMessage = message
            case let .searchProgress(request, progress) where request == searchRequest:
                searchProgress = (progress.structuresScanned, progress.totalStructures)
                searchResults.append(contentsOf: progress.matches)
                if let structure = progress.currentStructure {
                    if !progress.matches.isEmpty { searchGroups.append((structure, progress.matches)) }
                    searchMessage = "Scanned \(progress.structuresScanned)/\(progress.totalStructures): \(displayName(structure.structureID))"
                }
            case let .searchFinished(request, containers, message) where request == searchRequest:
                searchResults = containers
                if containers.isEmpty { searchGroups = [] }
                searchRunning = false
                searchMessage = message
            case let .failure(generation, message) where generation == renderGeneration:
                pendingTileCount = 0
                status = message
                biomeGenerationStatus = "Biomes: generation failed."
                structureGenerationStatus = "Structures: generation failed."
            default:
                break
            }
        }
    }

    private func install(structures: MapTileStructuresPresentation) {
        let key = SDLTileKey(seed: structures.seed, sampleY: sampleY, scaleKey: structures.scaleKey, tileX: structures.tileX, tileZ: structures.tileZ)
        // A previous viewport generation may still have a raster for this coordinate. Do not
        // merge a new marker result into it: the later biome result would overwrite the markers.
        guard let existing = tiles[key], existing.generation == structures.generation else {
            deferredStructureResults[key] = structures
            return
        }
        let updated = MapTilePresentation(
            generation: existing.generation, seed: existing.seed, scaleKey: existing.scaleKey,
            tileX: existing.tileX, tileZ: existing.tileZ, width: existing.width, height: existing.height,
            palette: existing.palette, biomeIndices: existing.biomeIndices, structures: structures.structures,
            structuresComplete: true,
            generationMilliseconds: existing.generationMilliseconds,
            densityCompilationMilliseconds: existing.densityCompilationMilliseconds,
            densityCompilationBackend: existing.densityCompilationBackend
        )
        tiles[key] = updated
        structureMarkerTileRevision &+= 1
        tile = updated
    }

    func changeDatapackVersion(by offset: Int) {
        // Version controls can be activated while the seed editor still owns a snapshot (most
        // commonly Paste followed immediately by a version change during startup). Commit it
        // here rather than relying on the preceding mouse event to have blurred the editor.
        blur()
        guard let index = vanillaDatapacks.firstIndex(of: selectedDatapack) else { return }
        let nextIndex = min(max(0, index + offset), vanillaDatapacks.count - 1)
        guard nextIndex != index else { return }
        selectedDatapack = vanillaDatapacks[nextIndex]
        invalidateLoot()
        platformReady = false
        generationPlatform = nil
        generationPlatformRoot = nil
        generationPlatformPackFormat = nil
        removeAllTiles()
        tile = nil
        loot.removeAll(keepingCapacity: true)
        loadedBiomeIDs.removeAll(keepingCapacity: true)
        loadedStructureIDs.removeAll(keepingCapacity: true)
        enabledStructureSets.removeAll(keepingCapacity: true)
        selectedColorID = nil
        needsTextureRebuild = true
        status = "Loading Minecraft \(selectedDatapack.version)…"
        requestRegenerate()
    }

    func datapackRoot(for datapack: VanillaDatapack) throws -> URL {
        let fileManager = FileManager.default
        let override = ProcessInfo.processInfo.environment["DAPPERMAP_DATAPACK"]?
            .replacingOccurrences(of: "{version}", with: datapack.version)
        let candidates = [override, datapack.nativeDataDirectory]
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.appendingPathComponent("data/minecraft/worldgen/biome").path) { return candidate }
        throw NSError(
            domain: "DapperMap",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Extract Minecraft \(datapack.version) to \(datapack.nativeDataDirectory), or set DAPPERMAP_DATAPACK."]
        )
    }


    func biomeColor(_ biome: String) -> (UInt8, UInt8, UInt8) {
        let color = biomeColors[biome] ?? resolvedBiomeColor(for: biome)
        return (color.red, color.green, color.blue)
    }

    func formatDuration(_ milliseconds: Double) -> String {
        milliseconds >= 1_000 ? String(format: "%.1fs", milliseconds / 1_000) : String(format: "%.0fms", milliseconds)
    }

    func installTexture(for tile: MapTilePresentation, key: SDLTileKey, renderer: OpaquePointer) {
        guard let texture = SDL_CreateTexture(
            renderer, SDL_PIXELFORMAT_RGBA32.rawValue, Int32(SDL_TEXTUREACCESS_STATIC.rawValue),
            Int32(tile.width), Int32(tile.height)
        ) else { return }
        let pixels = tile.biomeIndices.map { biomeIndex -> UInt32 in
            let index = Int(biomeIndex)
            let color = biomeColor(tile.palette.indices.contains(index) ? tile.palette[index] : "unknown")
            return UInt32(color.0) | UInt32(color.1) << 8 | UInt32(color.2) << 16 | 0xff00_0000
        }
        let updateResult = pixels.withUnsafeBytes { bytes in
            SDL_UpdateTexture(texture, nil, bytes.baseAddress, Int32(tile.width * MemoryLayout<UInt32>.stride))
        }
        guard updateResult == 0 else {
            SDL_DestroyTexture(texture)
            return
        }
        SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_NONE)
        // Replace atomically from the cache's perspective: retaining the old texture on a
        // failed allocation or upload prevents blank tile-sized gaps during a rebuild.
        if let old = tileTextures.updateValue(texture, forKey: key) {
            SDL_DestroyTexture(old)
        }
    }

    func evictTileCacheIfNeeded() {
        while tiles.count > maximumCachedTiles {
            guard let oldest = tileRecency.min(by: { $0.value < $1.value })?.key else { break }
            tiles.removeValue(forKey: oldest)
            structureMarkerTileRevision &+= 1
            if let texture = tileTextures.removeValue(forKey: oldest) {
                SDL_DestroyTexture(texture)
            }
            tileRecency.removeValue(forKey: oldest)
        }
    }

    func removeAllTiles() {
        tileTextures.values.forEach(SDL_DestroyTexture)
        tileTextures.removeAll(keepingCapacity: true)
        tiles.removeAll(keepingCapacity: true)
        tileRecency.removeAll(keepingCapacity: true)
        structureMarkerTileRevision &+= 1
        structureMarkerCacheKey = nil
        structureMarkerCache.removeAll(keepingCapacity: true)
    }

}

final class SDLGenerationResults: @unchecked Sendable {
    enum Result {
        case registry(generation: Int, biomes: [String], structures: [String])
        case progress(generation: Int, message: String, elapsedMilliseconds: Double)
        case strongholds(generation: Int)
        case tile(generation: Int, tile: MapTilePresentation, completed: Int, total: Int, elapsedMilliseconds: Double)
        case biomeTile(generation: Int, tile: MapTilePresentation, completed: Int, total: Int, elapsedMilliseconds: Double)
        case tileStructures(generation: Int, structures: MapTileStructuresPresentation, completed: Int, total: Int, elapsedMilliseconds: Double)
        case finished(generation: Int, elapsedMilliseconds: Double)
        case loot(request: Int, containers: [MapLootPresentation], message: String)
        case searchProgress(request: Int, progress: LootSearchProgress)
        case searchFinished(request: Int, containers: [MapLootPresentation], message: String)
        case failure(generation: Int, message: String)
    }

    let lock = NSLock()
    var results: [Result] = []

    func store(_ result: Result) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    func take() -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }
}

private enum SDLTileWorkResult: Sendable {
    case biome(Result<MapTilePresentation, Error>)
    case structures(Result<MapTileStructuresPresentation, Error>)
}

struct SDLTileKey: Hashable {
    let seed: Int64
    let sampleY: Int32
    let scaleKey: Int
    let tileX: Int
    let tileZ: Int
}
