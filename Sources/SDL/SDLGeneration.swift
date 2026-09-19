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
        let requests = MapMath.centerFirstTileCoordinates(
            minTileX: minTileX,
            maxTileX: maxTileX,
            minTileZ: minTileZ,
            maxTileZ: maxTileZ,
            centerTileX: centerTileX,
            centerTileZ: centerTileZ
        ).map { tileX, tileZ in
                MapTileRequest(generation: generation, seed: seed, centerX: centerX, centerZ: centerZ,
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
        generationTask = Task.detached {
            do {
                results.store(.progress(generation: generation, message: "Preparing world generator…", elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                try await platform.initialize(rootURL: root, packFormat: datapack.packFormat)
                let registry = await platform.registryIDs()
                try Task.checkCancellation()
                results.store(.registry(generation: generation, biomes: registry.biomes, structures: registry.structures))
                results.store(.progress(generation: generation, message: "Generating centre tiles first…", elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                try await withThrowingTaskGroup(of: MapTilePresentation.self) { group in
                    var nextRequest = 0
                    for _ in 0..<min(workers, requests.count) {
                        let request = requests[nextRequest]
                        nextRequest += 1
                        group.addTask { try await platform.generateTile(request) }
                    }
                    var completed = 0
                    for try await tile in group {
                        try Task.checkCancellation()
                        if nextRequest < requests.count {
                            let request = requests[nextRequest]
                            nextRequest += 1
                            group.addTask { try await platform.generateTile(request) }
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
            case let .tile(generation, generatedTile, completed, total, elapsedMilliseconds) where generation == renderGeneration:
                let key = SDLTileKey(seed: generatedTile.seed, sampleY: sampleY, scaleKey: generatedTile.scaleKey, tileX: generatedTile.tileX, tileZ: generatedTile.tileZ)
                tiles[key] = generatedTile
                installTexture(for: generatedTile, key: key, renderer: renderer)
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

    func changeDatapackVersion(by offset: Int) {
        guard let index = vanillaDatapacks.firstIndex(of: selectedDatapack) else { return }
        let nextIndex = min(max(0, index + offset), vanillaDatapacks.count - 1)
        guard nextIndex != index else { return }
        selectedDatapack = vanillaDatapacks[nextIndex]
        invalidateLoot()
        platformReady = false
        generationPlatform = nil
        generationPlatformRoot = nil
        generationPlatformPackFormat = nil
        tiles.removeAll(keepingCapacity: true)
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
        if let old = tileTextures.removeValue(forKey: key) { SDL_DestroyTexture(old) }
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
        tileTextures[key] = texture
    }

}

final class SDLGenerationResults: @unchecked Sendable {
    enum Result {
        case registry(generation: Int, biomes: [String], structures: [String])
        case progress(generation: Int, message: String, elapsedMilliseconds: Double)
        case tile(generation: Int, tile: MapTilePresentation, completed: Int, total: Int, elapsedMilliseconds: Double)
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

struct SDLTileKey: Hashable {
    let seed: Int64
    let sampleY: Int32
    let scaleKey: Int
    let tileX: Int
    let tileZ: Int
}

