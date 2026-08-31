import DapperMapCore
import DapperMapEngine
import Foundation
import SDL2

@main
struct DapperMapSDLMain {
    @MainActor
    static func main() {
        guard SDL_Init(UInt32(SDL_INIT_VIDEO)) == 0 else {
            fputs("SDL initialization failed: \(String(cString: SDL_GetError()))\n", stderr)
            return
        }
        defer { SDL_Quit() }

        let app = SDLMapApplication()
        app.run()
    }
}

@MainActor
private final class SDLMapApplication {
    private var mapWidth = 768
    private var mapHeight = 640
    private let sidebarWidth = 280
    private var seed: Int64 = 0
    private var seedText = "0"
    private var sampleY: Int32 = 256
    private var editingSeed = false
    private var centerX = 0.0
    private var centerZ = 0.0
    private var blocksPerPixel = 4.0
    // Match the AppKit frontend: each worker owns a datapack, so starting one per CPU can use a
    // prohibitive amount of memory before the first tile is produced.
    private var threadCount = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    private var tile: MapTilePresentation?
    private var tiles: [SDLTileKey: MapTilePresentation] = [:]
    private var tileTextures: [SDLTileKey: OpaquePointer] = [:]
    private var needsTextureRebuild = false
    private var tooltip = ""
    private var loot: [MapLootPresentation] = []
    private var status = "Ready. Press R to render seed 0."
    private var biomeGenerationStatus = "Biomes: waiting."
    private var structureGenerationStatus = "Structures: waiting."
    private var sidebar: SidebarPresentation = DapperMapBase.sidebar()
    private var dragStart: (x: Int32, y: Int32)?
    private var dragOrigin = (x: 0.0, z: 0.0)
    private var dragged = false
    private var selectedTabID = "map"
    private var renderGeneration = 0
    private var pendingTileCount = 0
    private let generationResults = SDLGenerationResults()
    private var hasRendered = false
    private var loadedBiomeIDs: [String] = []
    private var loadedStructureIDs: [String] = []
    private var biomeColors: [String: BiomeColor] = [:]
    private var structureColors: [String: BiomeColor] = [:]
    private var enabledStructureSets: Set<String> = []
    private var selectedColorID: String?
    private var selectedColorIsStructure = false
    private var resizeDeadline: UInt32?
    private var generationPlatform: NativeGenerationPlatform?
    private var generationPlatformThreadCount = 0
    private var generationPlatformRoot: URL?

    func run() {
        guard let window = SDL_CreateWindow(
            "DapperMap SDL", Int32(bitPattern: 0x2FFF0000), Int32(bitPattern: 0x2FFF0000),
            Int32(mapWidth + sidebarWidth), Int32(mapHeight),
            SDL_WINDOW_SHOWN.rawValue | SDL_WINDOW_RESIZABLE.rawValue
        ) else {
            fputs("SDL window creation failed: \(String(cString: SDL_GetError()))\n", stderr)
            return
        }
        defer { SDL_DestroyWindow(window) }
        SDL_SetWindowMinimumSize(window, Int32(sidebarWidth + 256), 256)
        let rendererFlags = SDL_RENDERER_ACCELERATED.rawValue | SDL_RENDERER_PRESENTVSYNC.rawValue
        guard let renderer = SDL_CreateRenderer(window, -1, rendererFlags) else {
            fputs("SDL renderer creation failed: \(String(cString: SDL_GetError()))\n", stderr)
            return
        }
        defer { SDL_DestroyRenderer(renderer) }
        defer { tileTextures.values.forEach(SDL_DestroyTexture) }

        sidebar = DapperMapBase.sidebar(extraDebugFields: [
            SidebarField(id: "threads", label: "Threads", value: "\(threadCount)", kind: .integer(defaultValue: threadCount, range: 1...32))
        ])
        var running = true
        while running {
            var event = SDL_Event()
            while SDL_PollEvent(&event) != 0 {
                switch event.type {
                case SDL_QUIT.rawValue:
                    fputs("SDL received a quit event.\n", stderr)
                    running = false
                case SDL_WINDOWEVENT.rawValue:
                    guard event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED.rawValue else { break }
                    let width = max(sidebarWidth + 256, Int(event.window.data1))
                    mapWidth = width - sidebarWidth
                    mapHeight = max(256, Int(event.window.data2))
                    tooltip = ""
                    if hasRendered { resizeDeadline = SDL_GetTicks() &+ 150 }
                case SDL_KEYDOWN.rawValue:
                    let key = event.key.keysym.sym
                    if editingSeed {
                        if key == SDLK_RETURN.rawValue || key == SDLK_KP_ENTER.rawValue {
                            if let value = Int64(seedText) ?? UInt64(seedText).map({ Int64(bitPattern: $0) }) {
                                seed = value
                                editingSeed = false
                                requestRegenerate()
                            } else {
                                status = "ENTER A 64 BIT SEED"
                            }
                        } else if key == SDLK_BACKSPACE.rawValue {
                            if !seedText.isEmpty { seedText.removeLast() }
                        } else if key == SDLK_MINUS.rawValue, seedText.isEmpty {
                            seedText = "-"
                        } else if key >= 48, key <= 57, let scalar = UnicodeScalar(UInt32(key)) {
                            seedText.unicodeScalars.append(scalar)
                        }
                        break
                    }
                    if key == SDLK_ESCAPE.rawValue || key == SDLK_q.rawValue { running = false }
                    if key == SDLK_LEFTBRACKET.rawValue { threadCount = max(1, threadCount - 1); requestRegenerate() }
                    if key == SDLK_RIGHTBRACKET.rawValue { threadCount = min(32, threadCount + 1); requestRegenerate() }
                    if key == SDLK_PAGEUP.rawValue { sampleY = min(316, sampleY + 4); requestRegenerate() }
                    if key == SDLK_PAGEDOWN.rawValue { sampleY = max(-64, sampleY - 4); requestRegenerate() }
                    if key == SDLK_r.rawValue { requestRegenerate() }
                case SDL_MOUSEBUTTONDOWN.rawValue:
                    guard event.button.button == 1, event.button.x < Int32(mapWidth) else { break }
                    dragStart = (event.button.x, event.button.y)
                    dragOrigin = (centerX, centerZ)
                    dragged = false
                case SDL_MOUSEMOTION.rawValue:
                    if let dragStart {
                        let dx = event.motion.x - dragStart.x
                        let dz = event.motion.y - dragStart.y
                        dragged = dragged || abs(dx) + abs(dz) > 3
                        centerX = dragOrigin.x - Double(dx) * blocksPerPixel
                        centerZ = dragOrigin.z - Double(dz) * blocksPerPixel
                    } else {
                        updateTooltip(screenX: event.motion.x, screenY: event.motion.y)
                    }
                case SDL_MOUSEBUTTONUP.rawValue:
                    if event.button.button == 1, event.button.x >= Int32(mapWidth) {
                        selectSidebarTab(atX: event.button.x, y: event.button.y)
                        break
                    }
                    guard event.button.button == 1, dragStart != nil else { break }
                    self.dragStart = nil
                    if dragged, hasRendered {
                        requestRegenerate()
                    } else {
                        selectStructure(atX: event.button.x, y: event.button.y)
                    }
                case SDL_MOUSEWHEEL.rawValue:
                    var mouseX: Int32 = 0
                    var mouseY: Int32 = 0
                    _ = SDL_GetMouseState(&mouseX, &mouseY)
                    guard mouseX < Int32(mapWidth) else { break }
                    let before = worldPosition(screenX: mouseX, screenY: mouseY)
                    blocksPerPixel = min(256, max(0.125, blocksPerPixel * exp(-Double(event.wheel.y) * 0.15)))
                    let after = worldPosition(screenX: mouseX, screenY: mouseY)
                    centerX += before.x - after.x
                    centerZ += before.z - after.z
                    if hasRendered { requestRegenerate() }
                default: break
                }
            }
            if let resizeDeadline, SDL_GetTicks() >= resizeDeadline {
                self.resizeDeadline = nil
                requestRegenerate()
            }
            installCompletedGeneration(renderer: renderer)
            draw(renderer: renderer)
            SDL_Delay(10)
        }
    }

    private func requestRegenerate() {
        hasRendered = true
        renderGeneration &+= 1
        let generation = renderGeneration
        status = "Preparing world generator…"
        let root: URL
        do { root = try datapackRoot() }
        catch {
            status = "Datapack not found"
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
                    enabledStructureSets: enabledStructureSets)
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
           generationPlatformRoot == root {
            platform = cached
        } else {
            platform = NativeGenerationPlatform(threadCount: workers)
            generationPlatform = platform
            generationPlatformThreadCount = workers
            generationPlatformRoot = root
        }
        let results = generationResults
        let startedAt = Date()
        Task.detached {
            do {
                results.store(.progress(generation: generation, message: "Preparing world generator…", elapsedMilliseconds: Date().timeIntervalSince(startedAt) * 1_000))
                try await platform.initialize(rootURL: root)
                let registry = await platform.registryIDs()
                results.store(.registry(biomes: registry.biomes, structures: registry.structures))
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
            } catch {
                results.store(.failure(generation: generation, message: "Generation failed: \(error)"))
            }
        }
    }

    private func installCompletedGeneration(renderer: OpaquePointer) {
        while let result = generationResults.take() {
            switch result {
            case let .registry(biomes, structures):
                loadedBiomeIDs = biomes
                loadedStructureIDs = structures
                enabledStructureSets.formUnion(structures)
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
            case let .loot(seed, containers, message) where seed == self.seed:
                loot = containers
                selectedTabID = "loot"
                status = message
            case let .failure(generation, message) where generation == renderGeneration:
                status = message
                biomeGenerationStatus = "Biomes: generation failed."
                structureGenerationStatus = "Structures: generation failed."
            default:
                break
            }
        }
    }

    private func draw(renderer: OpaquePointer) {
        if needsTextureRebuild {
            tileTextures.values.forEach(SDL_DestroyTexture)
            tileTextures.removeAll(keepingCapacity: true)
            for (key, tile) in tiles { installTexture(for: tile, key: key, renderer: renderer) }
            needsTextureRebuild = false
        }
        SDL_SetRenderDrawColor(renderer, 247, 244, 234, 255)
        SDL_RenderClear(renderer)
        let tileBPP = MapMath.tileBlocksPerPixel(for: blocksPerPixel)
        let worldStartX = centerX - Double(mapWidth) * blocksPerPixel / 2
        let worldStartZ = centerZ - Double(mapHeight) * blocksPerPixel / 2
        let side = Double(MapMath.tileSize) * tileBPP / blocksPerPixel
        let activeScale = MapMath.scaleKey(for: tileBPP)
        for tile in tiles.values where tile.seed == seed && tile.scaleKey == activeScale {
            let originX = (Double(tile.tileX * MapMath.tileSize) * tileBPP - worldStartX) / blocksPerPixel
            let originZ = (Double(tile.tileZ * MapMath.tileSize) * tileBPP - worldStartZ) / blocksPerPixel
            let key = SDLTileKey(seed: tile.seed, sampleY: sampleY, scaleKey: tile.scaleKey, tileX: tile.tileX, tileZ: tile.tileZ)
            if let texture = tileTextures[key] {
                var destination = SDL_Rect(
                    x: Int32(originX.rounded(.down)), y: Int32(originZ.rounded(.down)),
                    w: max(1, Int32(side.rounded(.up))), h: max(1, Int32(side.rounded(.up)))
                )
                SDL_RenderCopy(renderer, texture, nil, &destination)
            }
            for marker in tile.structures {
                guard enabledStructureSets.contains(marker.setID) else { continue }
                let color = structureColors[marker.setID]
                    ?? defaultStructureColor(for: marker.setID)
                    ?? resolvedBiomeColor(for: marker.setID)
                SDL_SetRenderDrawColor(renderer, color.red, color.green, color.blue, 255)
                let x = Int32((Double(marker.x) - centerX) / blocksPerPixel + Double(mapWidth) / 2)
                let y = Int32((Double(marker.z) - centerZ) / blocksPerPixel + Double(mapHeight) / 2)
                var rect = SDL_Rect(x: x - 3, y: y - 3, w: 7, h: 7)
                SDL_RenderFillRect(renderer, &rect)
            }
        }
        drawGrid(renderer, worldStartX: worldStartX, worldStartZ: worldStartZ, tileBPP: tileBPP)
        if !tooltip.isEmpty { drawText(renderer, text: tooltip, x: 12, y: 12, scale: 1) }
        var panel = SDL_Rect(x: Int32(mapWidth), y: 0, w: Int32(sidebarWidth), h: Int32(mapHeight))
        SDL_SetRenderDrawColor(renderer, 35, 31, 29, 255)
        SDL_RenderFillRect(renderer, &panel)
        drawText(renderer, text: "DAPPERMAP SDL", x: mapWidth + 18, y: 22, scale: 3)
        drawSidebar(renderer)
        drawText(renderer, text: "DRAG MAP TO PAN", x: mapWidth + 18, y: mapHeight - 70, scale: 2)
        drawText(renderer, text: "R RENDER [] THREADS", x: mapWidth + 18, y: mapHeight - 36, scale: 1)
        SDL_RenderPresent(renderer)
    }

    private func drawSidebar(_ renderer: OpaquePointer) {
        for (index, tab) in sidebar.tabs.enumerated() {
            let y = 62 + index * 28
            if tab.id == selectedTabID {
                SDL_SetRenderDrawColor(renderer, 89, 78, 67, 255)
                var selected = SDL_Rect(x: Int32(mapWidth + 12), y: Int32(y - 5), w: Int32(sidebarWidth - 24), h: 23)
                SDL_RenderFillRect(renderer, &selected)
            }
            drawText(renderer, text: tab.title, x: mapWidth + 20, y: y, scale: 2)
        }
        guard let tab = sidebar.tabs.first(where: { $0.id == selectedTabID }) else { return }
        drawText(renderer, text: tab.heading, x: mapWidth + 18, y: 220, scale: 2)
        var y = 254
        for field in tab.fields where tab.id != "map" {
            drawText(renderer, text: field.label, x: mapWidth + 18, y: y, scale: 1)
            y += 14
            let value = field.id == "threads" ? "\(threadCount)" : field.value
            drawText(renderer, text: value, x: mapWidth + 18, y: y, scale: 2)
            y += 28
        }
        if tab.id == "map" {
            let cursor = editingSeed && (SDL_GetTicks() / 500).isMultiple(of: 2) ? "_" : ""
            drawText(renderer, text: "SEED", x: mapWidth + 18, y: y, scale: 1)
            drawText(renderer, text: "\(seedText)\(cursor)", x: mapWidth + 18, y: y + 16, scale: 2)
            drawText(renderer, text: "Y", x: mapWidth + 18, y: y + 48, scale: 1)
            drawText(renderer, text: "\(sampleY)  PGUP/PGDN", x: mapWidth + 18, y: y + 64, scale: 2)
            drawText(renderer, text: "STATUS", x: mapWidth + 18, y: y + 100, scale: 1)
            drawText(renderer, text: status, x: mapWidth + 18, y: y + 116, scale: 1)
            drawText(renderer, text: biomeGenerationStatus, x: mapWidth + 18, y: y + 138, scale: 1)
            drawText(renderer, text: structureGenerationStatus, x: mapWidth + 18, y: y + 160, scale: 1)
            drawText(renderer, text: "X \(Int(centerX)) Z \(Int(centerZ)) BPP \(blocksPerPixel)", x: mapWidth + 18, y: y + 182, scale: 1)
        } else if tab.id == "debug" {
            let last = tile.map { "\($0.tileX), \($0.tileZ)" } ?? "WAITING"
            drawText(renderer, text: "LAST TILE \(last)", x: mapWidth + 18, y: y, scale: 1)
            drawText(renderer, text: "GEN \(formatDuration(tile?.generationMilliseconds ?? 0))", x: mapWidth + 18, y: y + 22, scale: 1)
            if let milliseconds = tile?.densityCompilationMilliseconds,
               let backend = tile?.densityCompilationBackend {
                drawText(renderer, text: "DENSITY \(backend) \(formatDuration(milliseconds))", x: mapWidth + 18, y: y + 44, scale: 1)
            } else {
                drawText(renderer, text: "DENSITY NOT COMPILED", x: mapWidth + 18, y: y + 44, scale: 1)
            }
            drawText(renderer, text: "CACHED \(tiles.count)", x: mapWidth + 18, y: y + 66, scale: 1)
            drawText(renderer, text: "PENDING \(pendingTileCount)", x: mapWidth + 18, y: y + 88, scale: 1)
            drawText(renderer, text: "THREADS \(threadCount)", x: mapWidth + 18, y: y + 110, scale: 1)
        } else if tab.id == "biomes" {
            drawColorRows(renderer, ids: loadedBiomeIDs, colors: biomeColors, y: y, fallback: resolvedBiomeColor(for:))
            drawRGBPicker(renderer, ids: loadedBiomeIDs, isStructure: false)
        } else if tab.id == "structures" {
            drawStructureRows(renderer, y: y)
            drawRGBPicker(renderer, ids: loadedStructureIDs, isStructure: true)
        } else if tab.id == "loot" {
            if loot.isEmpty {
                drawText(renderer, text: "CLICK A STRUCTURE", x: mapWidth + 18, y: y, scale: 2)
            } else {
                for (index, container) in loot.prefix(8).enumerated() {
                    drawText(renderer, text: container.block, x: mapWidth + 18, y: y + index * 34, scale: 1)
                    drawText(renderer, text: "X \(container.x) Z \(container.z)", x: mapWidth + 18, y: y + index * 34 + 14, scale: 1)
                }
            }
        }
    }

    private func selectSidebarTab(atX x: Int32, y: Int32) {
        let index = Int((y - 57) / 28)
        if sidebar.tabs.indices.contains(index) {
            selectedTabID = sidebar.tabs[index].id
            return
        }
        if handleColorPickerClick(atX: x, y: y) { return }
        if selectedTabID == "map", y >= 250, y <= 305 {
            editingSeed = true
        } else if selectedTabID == "biomes", y >= 254 {
            let index = Int((y - 254) / 24)
            guard index < colorRowCount, loadedBiomeIDs.indices.contains(index) else { return }
            let id = loadedBiomeIDs[index]
            selectedColorID = id
            selectedColorIsStructure = false
        } else if selectedTabID == "structures", y >= 254 {
            let index = Int((y - 254) / 24)
            guard index < colorRowCount, loadedStructureIDs.indices.contains(index) else { return }
            let id = loadedStructureIDs[index]
            let rowX = Int(x) - mapWidth
            if rowX >= 18, rowX < 34 {
                if enabledStructureSets.contains(id) { enabledStructureSets.remove(id) } else { enabledStructureSets.insert(id) }
            } else {
                selectedColorID = id
                selectedColorIsStructure = true
            }
        }
    }

    private func datapackRoot() throws -> URL {
        let fileManager = FileManager.default
        let candidates = [ProcessInfo.processInfo.environment["DAPPERMAP_DATAPACK"], "Data/1.21.11"].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.appendingPathComponent("data/minecraft/worldgen/biome").path) { return candidate }
        throw NSError(domain: "DapperMap", code: 1)
    }


    private func biomeColor(_ biome: String) -> (UInt8, UInt8, UInt8) {
        let color = biomeColors[biome] ?? resolvedBiomeColor(for: biome)
        return (color.red, color.green, color.blue)
    }

    private var colorRowCount: Int { max(1, (mapHeight - 254 - 132) / 24) }
    private var colorPickerTop: Int { mapHeight - 108 }

    private func drawStructureRows(_ renderer: OpaquePointer, y: Int) {
        for (index, id) in loadedStructureIDs.prefix(colorRowCount).enumerated() {
            let rowY = y + index * 24
            SDL_SetRenderDrawColor(renderer, 238, 230, 210, 255)
            var checkbox = SDL_Rect(x: Int32(mapWidth + 18), y: Int32(rowY), w: 14, h: 14)
            SDL_RenderDrawRect(renderer, &checkbox)
            if enabledStructureSets.contains(id) {
                SDL_RenderDrawLine(renderer, checkbox.x + 3, checkbox.y + 7, checkbox.x + 6, checkbox.y + 11)
                SDL_RenderDrawLine(renderer, checkbox.x + 6, checkbox.y + 11, checkbox.x + 12, checkbox.y + 3)
            }
            let color = structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id)
            SDL_SetRenderDrawColor(renderer, color.red, color.green, color.blue, 255)
            var swatch = SDL_Rect(x: Int32(mapWidth + 40), y: Int32(rowY), w: 14, h: 14)
            SDL_RenderFillRect(renderer, &swatch)
            drawText(renderer, text: id, x: mapWidth + 62, y: rowY + 2, scale: 1)
        }
    }

    private func drawRGBPicker(_ renderer: OpaquePointer, ids: [String], isStructure: Bool) {
        guard let id = selectedColorID.flatMap({ selectedColorIsStructure == isStructure ? $0 : nil }) ?? ids.first else {
            drawText(renderer, text: "NO COLOURS LOADED", x: mapWidth + 18, y: colorPickerTop, scale: 1)
            return
        }
        let color = isStructure
            ? structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id)
            : biomeColors[id] ?? resolvedBiomeColor(for: id)
        drawText(renderer, text: "RGB \(id)", x: mapWidth + 18, y: colorPickerTop, scale: 1)
        let channels: [(String, UInt8, (UInt8, UInt8, UInt8))] = [
            ("R", color.red, (220, 70, 70)),
            ("G", color.green, (80, 190, 90)),
            ("B", color.blue, (70, 120, 230))
        ]
        for (index, channel) in channels.enumerated() {
            let y = colorPickerTop + 18 + index * 24
            drawText(renderer, text: "\(channel.0) \(channel.1)", x: mapWidth + 18, y: y, scale: 1)
            var track = SDL_Rect(x: Int32(mapWidth + 56), y: Int32(y + 1), w: 180, h: 8)
            SDL_SetRenderDrawColor(renderer, 86, 77, 69, 255)
            SDL_RenderFillRect(renderer, &track)
            track.w = Int32(Int(channel.1) * 180 / 255)
            SDL_SetRenderDrawColor(renderer, channel.2.0, channel.2.1, channel.2.2, 255)
            SDL_RenderFillRect(renderer, &track)
        }
    }

    private func handleColorPickerClick(atX x: Int32, y: Int32) -> Bool {
        guard selectedTabID == "biomes" || selectedTabID == "structures",
              y >= Int32(colorPickerTop + 18), y < Int32(colorPickerTop + 90),
              x >= Int32(mapWidth + 56), x <= Int32(mapWidth + 236)
        else { return false }
        let isStructure = selectedTabID == "structures"
        let ids = isStructure ? loadedStructureIDs : loadedBiomeIDs
        guard let id = selectedColorID.flatMap({ selectedColorIsStructure == isStructure ? $0 : nil }) ?? ids.first else { return true }
        let channel = min(2, max(0, Int((y - Int32(colorPickerTop + 18)) / 24)))
        let value = UInt8(clamping: Int((x - Int32(mapWidth + 56)) * 255 / 180))
        var color = isStructure
            ? structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id)
            : biomeColors[id] ?? resolvedBiomeColor(for: id)
        if channel == 0 { color.red = value }
        if channel == 1 { color.green = value }
        if channel == 2 { color.blue = value }
        selectedColorID = id
        selectedColorIsStructure = isStructure
        if isStructure {
            structureColors[id] = color
        } else {
            biomeColors[id] = color
            needsTextureRebuild = true
        }
        return true
    }

    private func selectStructure(atX x: Int32, y: Int32) {
        guard let structure = structure(nearX: x, y: y), let platform = generationPlatform else { return }
        status = "Generating loot for \(structure.structureID)…"
        selectedTabID = "loot"
        loot = []
        let results = generationResults
        let selectedSeed = seed
        Task.detached {
            do {
                let containers = try await platform.generateLoot(for: structure, seed: selectedSeed)
                results.store(.loot(seed: selectedSeed, containers: containers, message: containers.isEmpty ? "No supported loot containers." : "Loot generated."))
            } catch {
                results.store(.loot(seed: selectedSeed, containers: [], message: "Loot failed: \(error)"))
            }
        }
    }

    private func structure(nearX x: Int32, y: Int32) -> MapStructurePresentation? {
        let scale = MapMath.scaleKey(for: MapMath.tileBlocksPerPixel(for: blocksPerPixel))
        return tiles.values
            .filter { $0.seed == seed && $0.scaleKey == scale }
            .flatMap(\.structures)
            .filter { enabledStructureSets.contains($0.setID) }
            .compactMap { structure -> (MapStructurePresentation, Int64)? in
                let screenX = Int32((Double(structure.x) - centerX) / blocksPerPixel + Double(mapWidth) / 2)
                let screenY = Int32((Double(structure.z) - centerZ) / blocksPerPixel + Double(mapHeight) / 2)
                let dx = Int64(screenX - x)
                let dy = Int64(screenY - y)
                let distance = dx * dx + dy * dy
                return distance <= 100 ? (structure, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    private func formatDuration(_ milliseconds: Double) -> String {
        milliseconds >= 1_000 ? String(format: "%.1fs", milliseconds / 1_000) : String(format: "%.0fms", milliseconds)
    }

    private func installTexture(for tile: MapTilePresentation, key: SDLTileKey, renderer: OpaquePointer) {
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

    private func drawColorRows(
        _ renderer: OpaquePointer,
        ids: [String],
        colors: [String: BiomeColor],
        y: Int,
        fallback: (String) -> BiomeColor
    ) {
        for (index, id) in ids.prefix(colorRowCount).enumerated() {
            let color = colors[id] ?? fallback(id)
            SDL_SetRenderDrawColor(renderer, color.red, color.green, color.blue, 255)
            var swatch = SDL_Rect(x: Int32(mapWidth + 18), y: Int32(y + index * 24), w: 14, h: 14)
            SDL_RenderFillRect(renderer, &swatch)
            drawText(renderer, text: id, x: mapWidth + 40, y: y + index * 24 + 2, scale: 1)
        }
    }

    private func worldPosition(screenX: Int32, screenY: Int32) -> (x: Double, z: Double) {
        (
            centerX + (Double(screenX) - Double(mapWidth) / 2) * blocksPerPixel,
            centerZ + (Double(screenY) - Double(mapHeight) / 2) * blocksPerPixel
        )
    }

    private func updateTooltip(screenX: Int32, screenY: Int32) {
        guard screenX >= 0, screenX < Int32(mapWidth), screenY >= 0, screenY < Int32(mapHeight) else {
            tooltip = ""
            return
        }
        if let structure = structure(nearX: screenX, y: screenY) {
            tooltip = DapperMapBase.tooltipText(
                biome: nil,
                blockX: Int(structure.x),
                blockZ: Int(structure.z),
                structure: structure,
                container: nil
            )
            return
        }
        let world = worldPosition(screenX: screenX, screenY: screenY)
        let bpp = MapMath.tileBlocksPerPixel(for: blocksPerPixel)
        let span = Double(MapMath.tileSize) * bpp
        let tileX = Int(floor(world.x / span))
        let tileZ = Int(floor(world.z / span))
        let key = SDLTileKey(seed: seed, sampleY: sampleY, scaleKey: MapMath.scaleKey(for: bpp), tileX: tileX, tileZ: tileZ)
        guard let tile = tiles[key] else { tooltip = ""; return }
        let localX = min(max(Int(floor((world.x - Double(tileX) * span) / bpp)), 0), tile.width - 1)
        let localZ = min(max(Int(floor((world.z - Double(tileZ) * span) / bpp)), 0), tile.height - 1)
        let biome = tile.palette[Int(tile.biomeIndices[localZ * tile.width + localX])]
        tooltip = "\(biome) X \(Int(world.x)) Z \(Int(world.z))"
    }

    private func drawGrid(_ renderer: OpaquePointer, worldStartX: Double, worldStartZ: Double, tileBPP: Double) {
        let span = Double(MapMath.tileSize) * tileBPP
        let minX = Int(floor(worldStartX / span))
        let maxX = Int(ceil((worldStartX + Double(mapWidth) * blocksPerPixel) / span))
        let minZ = Int(floor(worldStartZ / span))
        let maxZ = Int(ceil((worldStartZ + Double(mapHeight) * blocksPerPixel) / span))
        SDL_SetRenderDrawColor(renderer, 30, 28, 24, 90)
        for tileX in minX...maxX {
            let x = Int32((Double(tileX) * span - worldStartX) / blocksPerPixel)
            SDL_RenderDrawLine(renderer, x, 0, x, Int32(mapHeight))
        }
        for tileZ in minZ...maxZ {
            let z = Int32((Double(tileZ) * span - worldStartZ) / blocksPerPixel)
            SDL_RenderDrawLine(renderer, 0, z, Int32(mapWidth), z)
        }
    }

    private func drawText(_ renderer: OpaquePointer, text: String, x: Int, y: Int, scale: Int) {
        SDL_SetRenderDrawColor(renderer, 238, 230, 210, 255)
        var cursor = x
        var lineY = y
        for char in text.uppercased() {
            if char == "\n" {
                cursor = x
                lineY += 8 * scale
                continue
            }
            for (row, bits) in Glyphs.rows(for: char).enumerated() {
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    var pixel = SDL_Rect(x: Int32(cursor + column * scale), y: Int32(lineY + row * scale), w: Int32(scale), h: Int32(scale))
                    SDL_RenderFillRect(renderer, &pixel)
                }
            }
            cursor += 6 * scale
        }
    }
}

private final class SDLGenerationResults: @unchecked Sendable {
    enum Result {
        case registry(biomes: [String], structures: [String])
        case progress(generation: Int, message: String, elapsedMilliseconds: Double)
        case tile(generation: Int, tile: MapTilePresentation, completed: Int, total: Int, elapsedMilliseconds: Double)
        case finished(generation: Int, elapsedMilliseconds: Double)
        case loot(seed: Int64, containers: [MapLootPresentation], message: String)
        case failure(generation: Int, message: String)
    }

    private let lock = NSLock()
    private var results: [Result] = []

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

private struct SDLTileKey: Hashable {
    let seed: Int64
    let sampleY: Int32
    let scaleKey: Int
    let tileX: Int
    let tileZ: Int
}

private enum Glyphs {
    static func rows(for char: Character) -> [Int] {
        let glyphs: [Character: [Int]] = [
            "A":[14,17,17,31,17,17,17], "B":[30,17,17,30,17,17,30], "C":[15,16,16,16,16,16,15], "D":[30,17,17,17,17,17,30], "E":[31,16,16,30,16,16,31], "F":[31,16,16,30,16,16,16], "G":[15,16,16,23,17,17,15], "H":[17,17,17,31,17,17,17], "I":[31,4,4,4,4,4,31], "J":[7,2,2,2,18,18,12], "K":[17,18,20,24,20,18,17], "L":[16,16,16,16,16,16,31], "M":[17,27,21,21,17,17,17], "N":[17,25,21,19,17,17,17], "O":[14,17,17,17,17,17,14], "P":[30,17,17,30,16,16,16], "Q":[14,17,17,17,21,18,13], "R":[30,17,17,30,20,18,17], "S":[15,16,16,14,1,1,30], "T":[31,4,4,4,4,4,4], "U":[17,17,17,17,17,17,14], "V":[17,17,17,17,17,10,4], "W":[17,17,17,21,21,21,10], "X":[17,17,10,4,10,17,17], "Y":[17,17,10,4,4,4,4], "Z":[31,1,2,4,8,16,31], "0":[14,17,19,21,25,17,14], "1":[4,12,4,4,4,4,14], "2":[14,17,1,2,4,8,31], "3":[30,1,1,14,1,1,30], "4":[2,6,10,18,31,2,2], "5":[31,16,16,30,1,1,30], "6":[14,16,16,30,17,17,14], "7":[31,1,2,4,8,8,8], "8":[14,17,17,14,17,17,14], "9":[14,17,17,15,1,1,14], " ":[0,0,0,0,0,0,0], "-":[0,0,0,31,0,0,0], ":":[0,4,0,0,4,0,0], ".":[0,0,0,0,0,6,6]
        ]
        return glyphs[char] ?? glyphs[" "]!
    }
}
