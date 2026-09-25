import Testing
import Foundation
import SDL2
import DapperMapCore
import DapperMapEngine
@testable import dappermap_sdl

@Test func textEditingPreservesSelectionAndUnicode() {
    var edit = SDLTextEditor(id: "seed", text: "123")
    edit.insert("-42")
    #expect(edit.text == "-42")
    edit.move(to: 1)
    edit.insert("9")
    #expect(edit.text == "-942")
    edit.move(to: 3, selecting: true)
    #expect(edit.selectedText == "4")
    edit.delete(backward: false)
    #expect(edit.text == "-92")
    edit.move(to: 0)
    edit.delete(backward: true)
    #expect(edit.text == "-92")
    edit.insert("é🙂\n")
    #expect(edit.text == "é🙂-92")
    edit.delete(backward: true)
    #expect(edit.text == "é-92")
    edit.move(to: 99)
    #expect(edit.visibleStart(capacity: 3) == 2)
}

@Test func worldSeedParsingPreservesNegativeBitPatterns() {
    #expect(MapMath.parseWorldSeed("-1") == -1)
    #expect(MapMath.parseWorldSeed("-9223372036854775808") == Int64.min)
    #expect(MapMath.parseWorldSeed("18446744073709551615") == -1)
}

@Test func wrappingHandlesLongItemIDsAndBlankLines() {
    let lines = wrappedSDLLines("minecraft:enchanted_golden_apple\n\nPotion of healing", columns: 12)
    #expect(lines.allSatisfy { $0.count <= 12 })
    #expect(lines.contains(""))
    #expect(lines.joined().contains("minecraft:enchanted_golden_apple"))
}

@Suite(.serialized) @MainActor
struct SDLInteractionTests {
    func withRenderer(_ body: (SDLMapApplication, OpaquePointer, UnsafeMutablePointer<SDL_Surface>) throws -> Void) throws {
        let surface = try #require(SDL_CreateRGBSurfaceWithFormat(0, 1148, 760, 32, SDL_PIXELFORMAT_RGBA32.rawValue))
        defer { SDL_FreeSurface(surface) }
        let renderer = try #require(SDL_CreateSoftwareRenderer(surface))
        defer { SDL_DestroyRenderer(renderer) }
        SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND)
        let app = SDLMapApplication()
        defer { app.tileTextures.values.forEach(SDL_DestroyTexture) }
        app.draw(renderer: renderer)
        try body(app, renderer, surface)
    }

    func click(_ app: SDLMapApplication, _ renderer: OpaquePointer, id: String) throws {
        let control = try #require(app.controls.first { $0.id == id })
        let x = control.hitBox.x + control.hitBox.width / 2
        let y = control.hitBox.y + control.hitBox.height / 2
        #expect(control.hitBox.height > 0)
        var event = SDL_Event()
        event.type = SDL_MOUSEBUTTONDOWN.rawValue
        event.button.button = 1; event.button.x = Int32(x); event.button.y = Int32(y)
        #expect(app.handle(event))
        event.type = SDL_MOUSEBUTTONUP.rawValue
        #expect(app.handle(event))
        app.draw(renderer: renderer)
    }

    func snapshot(_ surface: UnsafeMutablePointer<SDL_Surface>, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SDL_TEST_SCREENSHOTS"] else { return }
        if let stream = SDL_RWFromFile("\(directory)/\(name).bmp", "wb") { SDL_SaveBMP_RW(surface, stream, 1) }
    }

    @Test func leftPanelFocusHitRegionsAndSmallWindowScrolling() throws {
        try withRenderer { app, renderer, surface in
            try click(app, renderer, id: "seed")
            #expect(app.editor?.id == "seed")
            #expect(app.editor?.selectedText == "0")
            app.editor?.insert("18446744073709551615"); app.syncEditor()
            app.draw(renderer: renderer)
            snapshot(surface, name: "map-focused")
            try click(app, renderer, id: "tab:loot-search")
            #expect(app.editor == nil)
            #expect(app.selectedTabID == "loot-search")
            try click(app, renderer, id: "search")
            #expect(app.searchMessage.contains("Render a seed"))
            snapshot(surface, name: "search-form")
            let smallSurface = try #require(SDL_CreateRGBSurfaceWithFormat(0, 1148, 540, 32, SDL_PIXELFORMAT_RGBA32.rawValue))
            defer { SDL_FreeSurface(smallSurface) }
            let smallRenderer = try #require(SDL_CreateSoftwareRenderer(smallSurface))
            defer { SDL_DestroyRenderer(smallRenderer) }
            app.mapHeight = 540
            app.draw(renderer: smallRenderer)
            let hidden = try #require(app.controls.first { $0.id == "search" })
            #expect(hidden.hitBox.height == 0)
            #expect(app.controlAt(hidden.box.x + 2, hidden.box.y + 2)?.id != "search")
            for _ in 0..<3 { try click(app, smallRenderer, id: "scroll-down") }
            #expect(app.scrollOffset > 0)
            snapshot(smallSurface, name: "small-search-scrolled")
            #expect(app.worldPosition(screenX: Int32(app.sidebarWidth + app.mapWidth / 2), screenY: Int32(app.mapHeight / 2)).x == 0)
            #expect(app.screenPosition(x: 0, z: 0).x == app.sidebarWidth + app.mapWidth / 2)
        }
    }

    @Test func resultsShowItemsAndIgnoreStaleRequests() throws {
        try withRenderer { app, renderer, surface in
            let structure = MapStructurePresentation(setID: "minecraft:villages", structureID: "minecraft:village_plains", x: 24, z: -40)
            let chest = MapLootPresentation(block: "minecraft:chest", lootTable: "test", x: 25, y: 64, z: -39, items: ["3 minecraft:diamond", "1 minecraft:diamond_sword [sharpness 5]", "4 minecraft:bread"])
            app.generationResults.store(.loot(request: app.lootRequest - 1, containers: [chest], message: "stale"))
            app.installCompletedGeneration(renderer: renderer)
            #expect(app.loot.isEmpty)
            app.searchRunning = true
            let request = app.searchRequest
            app.generationResults.store(.searchProgress(request: request, progress: LootSearchProgress(structuresScanned: 1, totalStructures: 2, currentStructure: structure, matches: [chest])))
            app.installCompletedGeneration(renderer: renderer)
            #expect(app.searchResults == [chest])
            #expect(app.searchGroups.count == 1)
            app.cancelSearch()
            app.generationResults.store(.searchFinished(request: request, containers: [], message: "obsolete"))
            app.installCompletedGeneration(renderer: renderer)
            #expect(app.searchResults == [chest])
            #expect(app.searchMessage.contains("Cancelled"))
            app.searchedItem = "diamond"
            app.switchTab("loot-search")
            app.draw(renderer: renderer)
            app.scroll(by: app.maxScroll - 170)
            app.draw(renderer: renderer)
            snapshot(surface, name: "search-results")
            #expect(app.resultText(search: true).contains("sharpness 5"))
            app.activate("container:0")
            #expect(app.centerX == 25 && app.centerZ == -39)
            #expect(app.selectedContainer == chest)
            app.invalidateLoot()
            #expect(app.searchResults.isEmpty && app.selectedContainer == nil)
        }
    }

    @Test func sortedSearchResultsStillNavigateToTheDisplayedContainer() throws {
        try withRenderer { app, renderer, _ in
            let first = MapLootPresentation(block: "chest", lootTable: "test", x: 100, y: 64, z: 100, items: ["gold"])
            let second = MapLootPresentation(block: "chest", lootTable: "test", x: -100, y: 64, z: -100, items: ["gold"])
            let structure = MapStructurePresentation(setID: "villages", structureID: "village", x: 100, z: 100)
            app.searchGroups = [(structure, [first]), (structure, [second])]
            app.searchResults = [second, first] // Engine sorts final results by coordinates.
            app.switchTab("loot-search")
            app.draw(renderer: renderer)
            let firstButton = try #require(app.controls.first { $0.id.hasPrefix("container:") })
            app.activate(firstButton.id)
            #expect(app.selectedContainer == first)
            #expect(app.centerX == 100 && app.centerZ == 100)
        }
    }

    @Test func textInputEventsDoNotTriggerMapShortcuts() throws {
        try withRenderer { app, renderer, _ in
            app.switchTab("loot-search")
            app.draw(renderer: renderer)
            try click(app, renderer, id: "item")
            var event = SDL_Event()
            event.type = SDL_TEXTINPUT.rawValue
            withUnsafeMutableBytes(of: &event.text.text) { bytes in
                for (index, byte) in Array("enchant:sharpness 5".utf8).enumerated() { bytes[index] = byte }
            }
            #expect(app.handle(event))
            #expect(app.fields["item"] == "enchant:sharpness 5")
            event = SDL_Event()
            event.type = SDL_KEYDOWN.rawValue; event.key.keysym.sym = Int32(SDLK_ESCAPE.rawValue)
            #expect(app.handle(event))
            #expect(app.editor == nil)
            #expect(!app.hasRendered)
        }
    }

    @Test func registryRefreshPreservesHiddenStructuresAndRejectsOldVersion() throws {
        try withRenderer { app, renderer, _ in
            app.loadedStructureIDs = ["minecraft:villages"]
            app.generationResults.store(.registry(generation: app.renderGeneration, biomes: [], structures: ["minecraft:villages", "minecraft:desert_pyramids"]))
            app.installCompletedGeneration(renderer: renderer)
            #expect(!app.enabledStructureSets.contains("minecraft:villages"))
            #expect(app.enabledStructureSets.contains("minecraft:desert_pyramids"))
            app.generationResults.store(.registry(generation: app.renderGeneration - 1, biomes: ["stale"], structures: ["stale"]))
            app.installCompletedGeneration(renderer: renderer)
            #expect(!app.loadedStructureIDs.contains("stale"))
        }
    }

    @Test func markersRemainAboveTilesWithCorrectHeightAndLeftOffset() throws {
        try withRenderer { app, renderer, surface in
            let structure = MapStructurePresentation(setID: "minecraft:villages", structureID: "minecraft:village_plains", x: 0, z: 0)
            let tile = MapTilePresentation(generation: 1, seed: 0, scaleKey: 4096, tileX: 0, tileZ: 0, width: 1, height: 1, palette: ["minecraft:plains"], biomeIndices: [0], structures: [structure], generationMilliseconds: 1)
            let key = SDLTileKey(seed: 0, sampleY: 256, scaleKey: 4096, tileX: 0, tileZ: 0)
            app.tiles[key] = tile
            app.installTexture(for: tile, key: key, renderer: renderer)
            app.enabledStructureSets = [structure.setID]
            app.hasRendered = true
            app.structureColors[structure.setID] = BiomeColor(red: 255, green: 0, blue: 0)
            app.draw(renderer: renderer)
            #expect(app.visibleStructures.count == 1)
            let point = app.screenPosition(x: 0, z: 0)
            #expect(app.structure(nearX: Int32(point.x + 8), y: Int32(point.y)) == structure)
            let pixels = try #require(surface.pointee.pixels).assumingMemoryBound(to: UInt8.self)
            let offset = point.y * Int(surface.pointee.pitch) + point.x * 4
            #expect(pixels[offset] == 255 && pixels[offset + 1] == 0)
            #expect(pixels[offset - 3 * 4] == 20) // black outline around a four-pixel marker
            snapshot(surface, name: "markers")
            app.sampleY = 100
            #expect(app.visibleStructures.isEmpty)
        }
    }
}

// Opt in because vanilla datapacks are local data, not SwiftPM test resources.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SDL_TEST_DATAPACK"] != nil)) @MainActor
func liveSDLSearchUsesBundledGenerator() async throws {
    let root = try #require(ProcessInfo.processInfo.environment["SDL_TEST_DATAPACK"])
    let platform = NativeGenerationPlatform(threadCount: 1, lootSearchThreadCount: 1)
    try await platform.initialize(rootURL: URL(fileURLWithPath: root), packFormat: defaultVanillaDatapack.packFormat)
    let app = SDLMapApplication()
    app.hasRendered = true; app.platformReady = true; app.generationPlatform = platform; app.seed = 123458
    app.fields["search-x"] = "-328"; app.fields["search-z"] = "120"
    app.fields["radius"] = "32"; app.fields["item"] = "gold"
    let surface = try #require(SDL_CreateRGBSurfaceWithFormat(0, 1148, 760, 32, SDL_PIXELFORMAT_RGBA32.rawValue))
    defer { SDL_FreeSurface(surface) }
    let renderer = try #require(SDL_CreateSoftwareRenderer(surface))
    defer { SDL_DestroyRenderer(renderer) }
    app.startSearch()
    let task = try #require(app.searchTask)
    await task.value
    app.installCompletedGeneration(renderer: renderer)
    #expect(!app.searchRunning)
    #expect(app.searchMessage.hasPrefix("Found"))
    #expect(!app.searchResults.isEmpty)
    #expect(app.searchResults.allSatisfy { $0.items.contains { LootSearchMatcher.matches(item: $0, query: "gold") } })
    #expect(app.searchGroups.flatMap { $0.1 }.count == app.searchResults.count)
    app.switchTab("loot-search")
    app.draw(renderer: renderer)
    app.scroll(by: app.maxScroll - 120)
    app.draw(renderer: renderer)
    if let directory = ProcessInfo.processInfo.environment["SDL_TEST_SCREENSHOTS"], let stream = SDL_RWFromFile("\(directory)/live-search.bmp", "wb") { SDL_SaveBMP_RW(surface, stream, 1) }
}
