import DapperMapCore
import DapperMapEngine
import DPReader
import Foundation
import SDL2

@MainActor
final class SDLMapApplication {
    var mapWidth = 768
    var mapHeight = 760
    let sidebarWidth = 380
    var seed: Int64 = 0
    var sampleY: Int32 = 256
    var centerX = 0.0
    var centerZ = 0.0
    var blocksPerPixel = 4.0
    // Match the AppKit frontend: each worker owns a datapack, so starting one per CPU can use a
    // prohibitive amount of memory before the first tile is produced.
    var threadCount = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
    var lootSearchThreadCount = 1
    var enableDensityCompilation = ProcessInfo.processInfo.environment["DAPPERMAP_ENABLE_LLVM"] == "1"
    var tile: MapTilePresentation?
    var tiles: [SDLTileKey: MapTilePresentation] = [:]
    var tileTextures: [SDLTileKey: OpaquePointer] = [:]
    var needsTextureRebuild = false
    var tooltip = ""
    var loot: [MapLootPresentation] = []
    var status = "Enter a seed and click Render."
    var biomeGenerationStatus = "Biomes: waiting."
    var structureGenerationStatus = "Structures: waiting."
    var sidebar: SidebarPresentation = DapperMapBase.sidebar()
    var dragStart: (x: Int32, y: Int32)?
    var dragOrigin = (x: 0.0, z: 0.0)
    var dragged = false
    var selectedTabID = "map"
    var renderGeneration = 0
    var pendingTileCount = 0
    let generationResults = SDLGenerationResults()
    var hasRendered = false
    var loadedBiomeIDs: [String] = []
    var loadedStructureIDs: [String] = []
    var biomeColors: [String: BiomeColor] = [:]
    var structureColors: [String: BiomeColor] = [:]
    var enabledStructureSets: Set<String> = []
    var selectedColorID: String?
    var selectedColorIsStructure = false
    var resizeDeadline: UInt32?
    var platformReady = false
    var generationPlatform: NativeGenerationPlatform?
    var generationPlatformThreadCount = 0
    var generationPlatformLootSearchThreadCount = 0
    var generationPlatformUsesLLVM = false
    var generationPlatformRoot: URL?
    var generationPlatformPackFormat: Version?
    var selectedDatapack = defaultVanillaDatapack

    var fields: [String: String] = ["seed": "0", "y": "256", "x": "0", "z": "0", "search-x": "0", "search-z": "0", "radius": "512", "item": "", "filter": "", "biome-filter": "", "structure-filter": ""]
    var editor: SDLTextEditor?
    var controls: [SDLControl] = []
    var scrollOffsets: [String: Int] = [:]
    var contentHeight = 0
    var mouse = (x: 0, y: 0)
    var pressedControl: String?
    var scrollDragStart: (y: Int, offset: Int)?
    var lootRequest = 0
    var lootMessage = "Click a structure on the map to inspect its loot."
    var searchRequest = 0
    var searchTask: Task<Void, Never>?
    var generationTask: Task<Void, Never>?
    var searchRunning = false
    var searchMessage = "Enter a location and item, then click Search."
    var searchResults: [MapLootPresentation] = []
    var searchGroups: [(MapStructurePresentation, [MapLootPresentation])] = []
    var searchProgress = (done: 0, total: 0)
    var searchedItem = ""
    var selectedContainer: MapLootPresentation?
    var revealContainer: MapLootPresentation?
    let contentTop = 176
    var contentBottom: Int { mapHeight - 92 }
    var scrollOffset: Int { scrollOffsets[selectedTabID, default: 0] }
    var maxScroll: Int { max(0, contentHeight - (contentBottom - contentTop)) }
    var tabItems: [(id: String, title: String)] {
        sidebar.tabs.map { ($0.id, $0.title) } + [("about", "About")]
    }

    func run() {
        guard let window = SDL_CreateWindow(
            "DapperMap SDL", Int32(bitPattern: 0x2FFF0000), Int32(bitPattern: 0x2FFF0000),
            Int32(mapWidth + sidebarWidth), Int32(mapHeight),
            SDL_WINDOW_SHOWN.rawValue | SDL_WINDOW_RESIZABLE.rawValue | SDL_WINDOW_ALLOW_HIGHDPI.rawValue
        ) else { fputs("SDL window: \(String(cString: SDL_GetError()))\n", stderr); return }
        defer { SDL_DestroyWindow(window) }
        SDL_SetWindowMinimumSize(window, Int32(sidebarWidth + 300), 540)
        let flags = SDL_RENDERER_ACCELERATED.rawValue | SDL_RENDERER_PRESENTVSYNC.rawValue
        guard let renderer = SDL_CreateRenderer(window, -1, flags) ?? SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE.rawValue) else {
            fputs("SDL renderer: \(String(cString: SDL_GetError()))\n", stderr); return
        }
        defer {
            generationTask?.cancel()
            searchTask?.cancel()
            tileTextures.values.forEach(SDL_DestroyTexture)
            SDL_DestroyRenderer(renderer)
            SDL_StopTextInput()
        }
        SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND)
        let arrow = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW)
        let textCursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_IBEAM)
        let hand = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_HAND)
        let pan = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEALL)
        defer { [arrow, textCursor, hand, pan].compactMap { $0 }.forEach(SDL_FreeCursor) }
        var running = true
        draw(renderer: renderer)
        while running {
            var event = SDL_Event()
            while SDL_PollEvent(&event) != 0 {
                running = handle(event) && running
                // Rebuild hit regions after each event, including tab/scroll/resize changes.
                draw(renderer: renderer)
            }
            if let resizeDeadline, SDL_GetTicks() >= resizeDeadline {
                self.resizeDeadline = nil
                requestRegenerate()
            }
            installCompletedGeneration(renderer: renderer)
            let hovered = controlAt(mouse.x, mouse.y)
            let cursor = dragStart != nil ? pan : hovered?.field == true ? textCursor : hovered != nil ? hand : arrow
            if let cursor, SDL_GetCursor() != cursor { SDL_SetCursor(cursor) }
            draw(renderer: renderer)
            SDL_Delay(16)
        }
    }

    func handle(_ event: SDL_Event) -> Bool {
        switch event.type {
        case SDL_QUIT.rawValue: return false
        case SDL_WINDOWEVENT.rawValue:
            if event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED.rawValue {
                mapWidth = max(300, Int(event.window.data1) - sidebarWidth)
                mapHeight = max(540, Int(event.window.data2))
                tooltip = ""
                if hasRendered { resizeDeadline = SDL_GetTicks() &+ 150 }
            } else if event.window.event == SDL_WINDOWEVENT_FOCUS_LOST.rawValue {
                dragStart = nil
                pressedControl = nil
                scrollDragStart = nil
                blur()
            }
        case SDL_TEXTINPUT.rawValue:
            var input = event.text.text
            let value = withUnsafePointer(to: &input) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            editor?.insert(value)
            syncEditor()
        case SDL_KEYDOWN.rawValue:
            handleKey(event.key)
        case SDL_MOUSEBUTTONDOWN.rawValue where event.button.button == 1:
            mouse = (Int(event.button.x), Int(event.button.y))
            if mouse.x >= sidebarWidth - 14, mouse.x < sidebarWidth, mouse.y >= contentTop, mouse.y < contentBottom, maxScroll > 0 {
                let trackHeight = contentBottom - contentTop
                let thumbHeight = max(24, trackHeight * trackHeight / max(1, contentHeight))
                let thumbTop = contentTop + (trackHeight - thumbHeight) * scrollOffset / maxScroll
                if mouse.y < thumbTop || mouse.y >= thumbTop + thumbHeight {
                    scrollOffsets[selectedTabID] = min(maxScroll, max(0, (mouse.y - contentTop - thumbHeight / 2) * maxScroll / max(1, trackHeight - thumbHeight)))
                }
                scrollDragStart = (mouse.y, scrollOffset)
            } else if let control = controlAt(mouse.x, mouse.y) {
                if control.field {
                    if editor?.id == control.id, var edit = editor {
                        let start = edit.visibleStart(capacity: (control.box.width - 16) / 12)
                        edit.move(to: start + max(0, (mouse.x - control.box.x - 8) / 12))
                        editor = edit
                    } else { focus(control.id) }
                } else { blur(); pressedControl = control.id }
            } else {
                blur()
                if mouse.x >= sidebarWidth {
                    dragStart = (event.button.x, event.button.y)
                    dragOrigin = (centerX, centerZ)
                    dragged = false
                }
            }
        case SDL_MOUSEMOTION.rawValue:
            mouse = (Int(event.motion.x), Int(event.motion.y))
            if let start = scrollDragStart {
                let trackHeight = contentBottom - contentTop
                let thumbHeight = max(24, trackHeight * trackHeight / max(1, contentHeight))
                scrollOffsets[selectedTabID] = min(maxScroll, max(0, start.offset + (mouse.y - start.y) * maxScroll / max(1, trackHeight - thumbHeight)))
            } else if let start = dragStart {
                let dx = event.motion.x - start.x, dz = event.motion.y - start.y
                dragged = dragged || abs(dx) + abs(dz) > 3
                centerX = dragOrigin.x - Double(dx) * blocksPerPixel
                centerZ = dragOrigin.z - Double(dz) * blocksPerPixel
                tooltip = ""
            } else { updateTooltip(screenX: event.motion.x, screenY: event.motion.y) }
        case SDL_MOUSEBUTTONUP.rawValue where event.button.button == 1:
            let x = Int(event.button.x), y = Int(event.button.y)
            mouse = (x, y)
            if let pressedControl, controlAt(x, y)?.id == pressedControl { activate(pressedControl) }
            pressedControl = nil
            scrollDragStart = nil
            if dragStart != nil {
                dragStart = nil
                if dragged { if hasRendered { requestRegenerate() } }
                else if x >= sidebarWidth { selectStructure(atX: event.button.x, y: event.button.y) }
            }
        case SDL_MOUSEWHEEL.rawValue:
            var x: Int32 = 0, y: Int32 = 0
            SDL_GetMouseState(&x, &y)
            let direction = event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED.rawValue ? -1 : 1
            let amount = Int(event.wheel.y) * direction
            if x < sidebarWidth { scroll(by: -amount * 48) }
            else { zoom(by: exp(-Double(amount) * 0.15), x: x, y: y) }
        default: break
        }
        return true
    }

    func handleKey(_ event: SDL_KeyboardEvent) {
        let key = event.keysym.sym
        let command = event.keysym.mod & UInt16(KMOD_CTRL.rawValue | KMOD_GUI.rawValue) != 0
        let shift = event.keysym.mod & UInt16(KMOD_SHIFT.rawValue) != 0
        if key == SDLK_TAB.rawValue {
            let ids = controls.filter { $0.field && $0.enabled }.map(\.id)
            guard !ids.isEmpty else { return }
            let index = editor.flatMap { ids.firstIndex(of: $0.id) } ?? (shift ? 0 : -1)
            focus(ids[(index + (shift ? -1 : 1) + ids.count) % ids.count])
            return
        }
        guard var edit = editor else {
            if key == SDLK_ESCAPE.rawValue { tooltip = ""; selectedContainer = nil }
            if key == SDLK_PAGEUP.rawValue { scroll(by: -(contentBottom - contentTop)) }
            if key == SDLK_PAGEDOWN.rawValue { scroll(by: contentBottom - contentTop) }
            return
        }
        if command && key == SDLK_a.rawValue { edit.anchor = 0; edit.cursor = edit.text.count }
        else if command && (key == SDLK_c.rawValue || key == SDLK_x.rawValue) {
            SDL_SetClipboardText(edit.selectedText)
            if key == SDLK_x.rawValue { edit.insert("") }
        } else if command && key == SDLK_v.rawValue {
            if let text = SDL_GetClipboardText() { edit.insert(String(cString: text)); SDL_free(text) }
        } else if key == SDLK_BACKSPACE.rawValue { edit.delete(backward: true) }
        else if key == SDLK_DELETE.rawValue { edit.delete(backward: false) }
        else if key == SDLK_LEFT.rawValue { edit.move(to: !shift && !edit.selection.isEmpty ? edit.selection.lowerBound : edit.cursor - 1, selecting: shift) }
        else if key == SDLK_RIGHT.rawValue { edit.move(to: !shift && !edit.selection.isEmpty ? edit.selection.upperBound : edit.cursor + 1, selecting: shift) }
        else if key == SDLK_HOME.rawValue { edit.move(to: 0, selecting: shift) }
        else if key == SDLK_END.rawValue { edit.move(to: edit.text.count, selecting: shift) }
        else if key == SDLK_ESCAPE.rawValue { blur(); return }
        else if key == SDLK_RETURN.rawValue || key == SDLK_KP_ENTER.rawValue {
            let id = edit.id
            blur()
            if ["seed", "y"].contains(id) { renderInputs() }
            else if ["x", "z"].contains(id) { activate("go") }
            else if selectedTabID == "loot-search" { startSearch() }
            return
        }
        editor = edit
        syncEditor()
    }

    func syncEditor() {
        guard let editor else { return }
        fields[editor.id] = editor.text
        if ["filter", "biome-filter", "structure-filter"].contains(editor.id) { scrollOffsets[selectedTabID] = 0 }
    }
    func blur() { syncEditor(); editor = nil; SDL_StopTextInput() }
    func focus(_ id: String) {
        blur()
        editor = SDLTextEditor(id: id, text: fields[id, default: ""])
        SDL_StartTextInput()
        if let control = controls.first(where: { $0.id == id }) {
            var rect = control.box.rect
            SDL_SetTextInputRect(&rect)
            if control.box.y < contentTop { scroll(by: control.box.y - contentTop) }
            else if control.box.y + control.box.height > contentBottom { scroll(by: control.box.y + control.box.height - contentBottom) }
        }
    }
    func controlAt(_ x: Int, _ y: Int) -> SDLControl? {
        controls.last { $0.enabled && $0.hitBox.contains(x, y) }
    }
    func scroll(by delta: Int) { scrollOffsets[selectedTabID] = min(maxScroll, max(0, scrollOffset + delta)) }
    func switchTab(_ id: String) { blur(); selectedTabID = id; tooltip = "" }
    func zoom(by factor: Double, x: Int32? = nil, y: Int32? = nil) {
        let x = x ?? Int32(sidebarWidth + mapWidth / 2), y = y ?? Int32(mapHeight / 2)
        let before = worldPosition(screenX: x, screenY: y)
        blocksPerPixel = min(256, max(0.125, blocksPerPixel * factor))
        let after = worldPosition(screenX: x, screenY: y)
        centerX += before.x - after.x; centerZ += before.z - after.z
        tooltip = ""
        if hasRendered { resizeDeadline = SDL_GetTicks() &+ 150 }
    }
    func renderInputs() {
        guard let value = Int64(fields["seed", default: ""]) ?? UInt64(fields["seed", default: ""]).map({ Int64(bitPattern: $0) }) else {
            status = "Seed must be a signed or unsigned 64-bit integer."; focus("seed"); return
        }
        guard let y = Int32(fields["y", default: ""]), (-64...316).contains(y) else {
            status = "Y must be a whole number from -64 to 316."; focus("y"); return
        }
        if seed != value || sampleY != y { invalidateLoot() }
        seed = value; sampleY = y
        requestRegenerate()
    }

    func activate(_ id: String) {
        if id.hasPrefix("tab:") { switchTab(String(id.dropFirst(4))); return }
        if id.hasPrefix("color:") { selectedColorID = String(id.dropFirst(6)); selectedColorIsStructure = selectedTabID == "structures"; scrollOffsets[selectedTabID] = 0; return }
        if id.hasPrefix("toggle:") {
            let set = String(id.dropFirst(7))
            if enabledStructureSets.contains(set) { enabledStructureSets.remove(set) } else { enabledStructureSets.insert(set) }
            return
        }
        if id.hasPrefix("channel:") { changeColor(id); return }
        if id.hasPrefix("container:") {
            let containers = selectedTabID == "loot-search" ? searchResults : filteredLoot
            if let index = Int(id.dropFirst(10)), containers.indices.contains(index) {
                selectedContainer = containers[index]
                centerX = Double(containers[index].x); centerZ = Double(containers[index].z)
                blocksPerPixel = min(blocksPerPixel, 1)
                if hasRendered { requestRegenerate() }
            }
            return
        }
        switch id {
        case "render": renderInputs()
        case "version-prev": changeDatapackVersion(by: -1)
        case "version-next": changeDatapackVersion(by: 1)
        case "copy-seed": SDL_SetClipboardText(fields["seed", default: ""])
        case "paste-seed":
            if let text = SDL_GetClipboardText() { fields["seed"] = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines); SDL_free(text) }
            focus("seed")
        case "random-seed": fields["seed"] = String(Int64.random(in: .min ... .max))
        case "go":
            guard let x = Int32(fields["x", default: ""]), let z = Int32(fields["z", default: ""]) else { status = "X and Z must be 32-bit whole numbers."; return }
            centerX = Double(x); centerZ = Double(z)
            if hasRendered { requestRegenerate() }
        case "origin": centerX = 0; centerZ = 0; if hasRendered { requestRegenerate() }
        case "zoom-in": zoom(by: 0.5)
        case "zoom-out": zoom(by: 2)
        case "scroll-up": scroll(by: -144)
        case "scroll-down": scroll(by: 144)
        case "all-structures": enabledStructureSets = Set(loadedStructureIDs)
        case "no-structures": enabledStructureSets = []
        case "reset-colors":
            if selectedTabID == "biomes" { biomeColors = [:]; needsTextureRebuild = true } else { structureColors = [:] }
        case "search-center": fields["search-x"] = String(Int(centerX)); fields["search-z"] = String(Int(centerZ))
        case "search": startSearch()
        case "cancel-search": cancelSearch()
        case "copy-results": SDL_SetClipboardText(resultText(search: selectedTabID == "loot-search"))
        case "threads-minus": threadCount = max(1, threadCount - 1)
        case "threads-plus": threadCount = min(32, threadCount + 1)
        case "search-threads-minus": lootSearchThreadCount = max(1, lootSearchThreadCount - 1)
        case "search-threads-plus": lootSearchThreadCount = min(4, lootSearchThreadCount + 1)
        case "llvm": enableDensityCompilation.toggle()
        case "apply-settings": invalidateLoot(); if hasRendered { requestRegenerate() }
        case "source": SDL_OpenURL("https://github.com/picawawa4000/dappermap")
        case "dpreader": SDL_OpenURL("https://github.com/picawawa4000/dpreader-swift")
        case "license": SDL_OpenURL("https://github.com/picawawa4000/dappermap/blob/main/LICENCE.txt")
        default: break
        }
    }

    var filteredLoot: [MapLootPresentation] {
        let query = fields["filter", default: ""]
        return query.isEmpty ? loot : loot.filter { $0.items.contains { LootSearchMatcher.matches(item: $0, query: query) } }
    }
    func cancelSearch() {
        searchTask?.cancel(); searchTask = nil; searchRequest &+= 1
        if searchRunning { searchMessage = "Cancelled. \(searchResults.count) matching containers kept." }
        searchRunning = false
    }
    func invalidateLoot() {
        cancelSearch(); lootRequest &+= 1
        loot = []; searchResults = []; searchGroups = []; selectedContainer = nil
        lootMessage = "Click a structure on the map to inspect its loot."
        searchMessage = "Enter a location and item, then click Search."
        searchProgress = (0, 0)
    }
    func startSearch() {
        guard hasRendered, let platform = generationPlatform else { searchMessage = "Render a seed in the Map tab before searching."; return }
        guard platformReady else { searchMessage = "World generator is still loading. Try Search when ready."; return }
        guard !fields["item", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searchMessage = "Enter an item, enchantment, potion or effect."; focus("item"); return }
        guard let x = Int32(fields["search-x", default: ""]), let z = Int32(fields["search-z", default: ""]),
              let radius = Int32(fields["radius", default: ""]), (1...10_000).contains(radius),
              Int64(x) - Int64(radius) >= Int32.min, Int64(x) + Int64(radius) <= Int32.max,
              Int64(z) - Int64(radius) >= Int32.min, Int64(z) + Int64(radius) <= Int32.max else {
            searchMessage = "Enter whole-number X/Z and a radius from 1 to 10,000 within 32-bit world coordinates."; return
        }
        cancelSearch()
        let request = searchRequest, selectedSeed = seed, results = generationResults
        searchedItem = fields["item", default: ""]
        let query = LootSearchQuery(startX: x, startZ: z, radius: radius, itemQuery: searchedItem)
        searchResults = []; searchGroups = []; searchProgress = (0, 0)
        searchRunning = true; searchMessage = "Finding structures..."
        searchTask = Task.detached {
            do {
                let containers = try await platform.searchLoot(query, seed: selectedSeed) { progress in
                    results.store(.searchProgress(request: request, progress: progress))
                }
                try Task.checkCancellation()
                results.store(.searchFinished(request: request, containers: containers, message: containers.isEmpty ? "No matching containers found." : "Found \(containers.count) matching containers."))
            } catch is CancellationError {
            } catch {
                results.store(.searchFinished(request: request, containers: [], message: "Search failed: \(error)"))
            }
        }
    }
    func resultText(search: Bool) -> String {
        let containers = search ? searchResults : filteredLoot
        return ([search ? searchMessage : lootMessage] + containers.map {
            "\($0.block) at (\($0.x), \($0.y), \($0.z))\n" + $0.items.joined(separator: "\n")
        }).joined(separator: "\n\n")
    }
    func selectStructure(atX x: Int32, y: Int32) {
        if let container = container(nearX: x, y: y) {
            selectedContainer = container
            revealContainer = container
            switchTab(searchResults.contains(container) ? "loot-search" : "loot")
            tooltip = DapperMapBase.tooltipText(biome: nil, blockX: Int(container.x), blockZ: Int(container.z), structure: nil, container: container)
            return
        }
        guard let structure = structure(nearX: x, y: y), let platform = generationPlatform else { return }
        lootRequest &+= 1
        let request = lootRequest, results = generationResults, selectedSeed = seed
        lootMessage = "Loading \(displayName(structure.structureID)) at \(structure.x), \(structure.z)..."
        switchTab("loot"); scrollOffsets["loot"] = 0; loot = []; selectedContainer = nil
        Task.detached {
            do {
                let containers = try await platform.generateLoot(for: structure, seed: selectedSeed)
                results.store(.loot(request: request, containers: containers, message: containers.isEmpty ? "No supported loot containers." : "\(structure.structureID): \(containers.count) containers."))
            } catch {
                results.store(.loot(request: request, containers: [], message: "Loot failed: \(error)"))
            }
        }
    }
    var visibleStructures: [MapStructurePresentation] {
        let scale = MapMath.scaleKey(for: MapMath.tileBlocksPerPixel(for: blocksPerPixel))
        return Array(Set(tiles.filter { $0.key.seed == seed && $0.key.sampleY == sampleY && $0.key.scaleKey == scale }.values.flatMap(\.structures)))
            .filter { enabledStructureSets.contains($0.setID) }
            .sorted { ($0.z, $0.x, $0.structureID) < ($1.z, $1.x, $1.structureID) }
    }
    var visibleContainers: [MapLootPresentation] {
        var result = selectedTabID == "loot-search" ? searchResults : loot
        if let selectedContainer, !result.contains(selectedContainer) { result.append(selectedContainer) }
        return result
    }
    func screenPosition(x: Int32, z: Int32) -> (x: Int, y: Int) {
        (Int((Double(x) - centerX) / blocksPerPixel + Double(mapWidth) / 2) + sidebarWidth,
         Int((Double(z) - centerZ) / blocksPerPixel + Double(mapHeight) / 2))
    }
    func worldPosition(screenX: Int32, screenY: Int32) -> (x: Double, z: Double) {
        (centerX + (Double(screenX) - Double(sidebarWidth) - Double(mapWidth) / 2) * blocksPerPixel,
         centerZ + (Double(screenY) - Double(mapHeight) / 2) * blocksPerPixel)
    }
    func structure(nearX x: Int32, y: Int32) -> MapStructurePresentation? {
        visibleStructures.min { distance($0.x, $0.z, x, y) < distance($1.x, $1.z, x, y) }
            .flatMap { distance($0.x, $0.z, x, y) <= 100 ? $0 : nil }
    }
    func container(nearX x: Int32, y: Int32) -> MapLootPresentation? {
        visibleContainers.min { distance($0.x, $0.z, x, y) < distance($1.x, $1.z, x, y) }
            .flatMap { distance($0.x, $0.z, x, y) <= 144 ? $0 : nil }
    }
    func distance(_ worldX: Int32, _ worldZ: Int32, _ x: Int32, _ y: Int32) -> Double {
        let point = screenPosition(x: worldX, z: worldZ)
        return pow(Double(point.x) - Double(x), 2) + pow(Double(point.y) - Double(y), 2)
    }
    func updateTooltip(screenX: Int32, screenY: Int32) {
        guard screenX >= sidebarWidth, screenX < sidebarWidth + mapWidth else { tooltip = ""; return }
        if let container = container(nearX: screenX, y: screenY) {
            tooltip = DapperMapBase.tooltipText(biome: nil, blockX: Int(container.x), blockZ: Int(container.z), structure: nil, container: container); return
        }
        if let structure = structure(nearX: screenX, y: screenY) {
            tooltip = DapperMapBase.tooltipText(biome: nil, blockX: Int(structure.x), blockZ: Int(structure.z), structure: structure, container: nil); return
        }
        let world = worldPosition(screenX: screenX, screenY: screenY)
        let bpp = MapMath.tileBlocksPerPixel(for: blocksPerPixel), span = Double(MapMath.tileSize) * bpp
        let tx = Int(floor(world.x / span)), tz = Int(floor(world.z / span))
        let key = SDLTileKey(seed: seed, sampleY: sampleY, scaleKey: MapMath.scaleKey(for: bpp), tileX: tx, tileZ: tz)
        guard let tile = tiles[key] else { tooltip = "X \(Int(floor(world.x)))  Z \(Int(floor(world.z)))"; return }
        let lx = min(max(Int((world.x - Double(tx) * span) / bpp), 0), tile.width - 1)
        let lz = min(max(Int((world.z - Double(tz) * span) / bpp), 0), tile.height - 1)
        let biome = tile.palette[Int(tile.biomeIndices[lz * tile.width + lx])]
        tooltip = "\(displayName(biome))\nX \(Int(floor(world.x)))  Z \(Int(floor(world.z)))"
    }

}
