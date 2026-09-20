import DapperMapCore
import DapperMapEngine
import DPReader
import Foundation
import SDL2

extension SDLMapApplication {
    func draw(renderer: OpaquePointer) {
        SDL_RenderSetScale(renderer, 1, 1)
        var outputWidth: Int32 = 0, outputHeight: Int32 = 0
        SDL_GetRendererOutputSize(renderer, &outputWidth, &outputHeight)
        SDL_RenderSetScale(renderer, Float(outputWidth) / Float(mapWidth + sidebarWidth), Float(outputHeight) / Float(mapHeight))
        if needsTextureRebuild {
            tileTextures.values.forEach(SDL_DestroyTexture); tileTextures.removeAll(keepingCapacity: true)
            for (key, tile) in tiles { installTexture(for: tile, key: key, renderer: renderer) }
            needsTextureRebuild = false
        }
        controls = []
        SDL_SetRenderDrawColor(renderer, 237, 230, 210, 255); SDL_RenderClear(renderer)
        var mapClip = SDL_Rect(x: Int32(sidebarWidth), y: 0, w: Int32(mapWidth), h: Int32(mapHeight))
        SDL_RenderSetClipRect(renderer, &mapClip)
        let bpp = MapMath.tileBlocksPerPixel(for: blocksPerPixel), scale = MapMath.scaleKey(for: MapMath.tileBlocksPerPixel(for: blocksPerPixel))
        let visibleKeys = tiles.keys.filter { $0.seed == seed && $0.sampleY == sampleY && $0.scaleKey == scale }
        for key in visibleKeys {
            tileRecencyClock &+= 1
            tileRecency[key] = tileRecencyClock
        }
        let startX = centerX - Double(mapWidth) * blocksPerPixel / 2, startZ = centerZ - Double(mapHeight) * blocksPerPixel / 2
        let side = Double(MapMath.tileSize) * bpp / blocksPerPixel
        for (key, tile) in tiles where key.seed == seed && key.sampleY == sampleY && key.scaleKey == scale {
            if let texture = tileTextures[key] {
                var destination = SDL_Rect(x: Int32(floor((Double(tile.tileX * MapMath.tileSize) * bpp - startX) / blocksPerPixel)) + Int32(sidebarWidth), y: Int32(floor((Double(tile.tileZ * MapMath.tileSize) * bpp - startZ) / blocksPerPixel)), w: Int32(ceil(side)), h: Int32(ceil(side)))
                SDL_RenderCopy(renderer, texture, nil, &destination)
            }
        }
        let span = Double(MapMath.tileSize) * bpp
        SDL_SetRenderDrawColor(renderer, 30, 28, 24, 45)
        for tx in Int(floor(startX / span))...Int(ceil((startX + Double(mapWidth) * blocksPerPixel) / span)) {
            let x = Int32((Double(tx) * span - startX) / blocksPerPixel) + Int32(sidebarWidth)
            SDL_RenderDrawLine(renderer, x, 0, x, Int32(mapHeight))
        }
        for tz in Int(floor(startZ / span))...Int(ceil((startZ + Double(mapHeight) * blocksPerPixel) / span)) {
            let y = Int32((Double(tz) * span - startZ) / blocksPerPixel)
            SDL_RenderDrawLine(renderer, Int32(sidebarWidth), y, Int32(sidebarWidth + mapWidth), y)
        }
        // Paint all markers after all tiles, so neighboring tile textures cannot cover them.
        let size = Int(max(4, min(9, 6 / sqrt(blocksPerPixel))))
        for marker in visibleStructures {
            let point = screenPosition(x: marker.x, z: marker.z)
            guard point.x >= sidebarWidth - 10, point.x < sidebarWidth + mapWidth + 10, point.y >= -10, point.y < mapHeight + 10 else { continue }
            let color = structureColors[marker.setID] ?? defaultStructureColor(for: marker.setID) ?? resolvedBiomeColor(for: marker.setID)
            fill(renderer, SDLBox(x: point.x - size / 2 - 1, y: point.y - size / 2 - 1, width: size + 2, height: size + 2), (20, 22, 20))
            fill(renderer, SDLBox(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), (color.red, color.green, color.blue))
        }
        for container in visibleContainers {
            let point = screenPosition(x: container.x, z: container.z)
            guard point.x >= sidebarWidth - 12, point.x < sidebarWidth + mapWidth + 12, point.y >= -12, point.y < mapHeight + 12 else { continue }
            let size = Int(max(5, min(11, 7 / sqrt(blocksPerPixel))))
            fill(renderer, SDLBox(x: point.x - size / 2 - 1, y: point.y - size / 2 - 1, width: size + 2, height: size + 2), (20, 22, 20))
            fill(renderer, SDLBox(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), (255, 242, 168))
            if container == selectedContainer { outline(renderer, SDLBox(x: point.x - 10, y: point.y - 10, width: 21, height: 21), (30, 80, 210)) }
        }
        if !hasRendered {
            let lines = wrappedSDLLines("Enter a seed in the Map panel, then click Render.", columns: max(12, (mapWidth - 60) / 12))
            for (index, line) in lines.enumerated() { drawText(renderer, text: line, x: sidebarWidth + 30, y: mapHeight / 2 + index * 22, scale: 2, color: (60, 62, 56)) }
        }
        if !tooltip.isEmpty && dragStart == nil {
            let width = min(400, mapWidth - 24)
            let lines = wrappedSDLLines(tooltip, columns: (width - 20) / 12)
            let shown = Array(lines.prefix(max(1, (mapHeight - 48) / 20)))
            let height = shown.count * 20 + 16
            let x = min(max(sidebarWidth + 12, mouse.x + 16), sidebarWidth + mapWidth - width - 12)
            let y = max(12, min(mouse.y + 20, mapHeight - height - 12))
            fill(renderer, SDLBox(x: x, y: y, width: width, height: height), (28, 34, 31))
            for (index, line) in shown.enumerated() { drawText(renderer, text: line, x: x + 10, y: y + 8 + index * 20, scale: 2) }
        }
        SDL_RenderSetClipRect(renderer, nil)
        button(renderer, "zoom-in", "+", SDLBox(x: sidebarWidth + mapWidth - 100, y: 12, width: 38, height: 32), content: false)
        button(renderer, "zoom-out", "-", SDLBox(x: sidebarWidth + mapWidth - 54, y: 12, width: 38, height: 32), content: false)
        drawSidebar(renderer)
        SDL_RenderPresent(renderer)
    }

    func drawSidebar(_ renderer: OpaquePointer) {
        fill(renderer, SDLBox(x: 0, y: 0, width: sidebarWidth, height: mapHeight), (32, 37, 34))
        drawText(renderer, text: "DapperMap", x: 16, y: 16, scale: 3)
        for (index, tab) in tabItems.enumerated() {
            let box = tab.id == "about"
                ? SDLBox(x: 282, y: 12, width: 82, height: 30)
                : SDLBox(x: 12 + (index % 2) * 182, y: 52 + (index / 2) * 36, width: 176, height: 30)
            button(renderer, "tab:\(tab.id)", tab.title, box, selected: selectedTabID == tab.id, content: false)
        }
        // A clipped content viewport and its hit regions always share the same geometry.
        let viewport = SDLBox(x: 0, y: contentTop, width: sidebarWidth - 14, height: contentBottom - contentTop)
        var clip = viewport.rect; SDL_RenderSetClipRect(renderer, &clip)
        var y = contentTop + 8 - scrollOffset
        func paragraph(_ text: String, color: (UInt8, UInt8, UInt8) = (216, 223, 213)) {
            for line in wrappedSDLLines(text, columns: 28) {
                drawText(renderer, text: line, x: 16, y: y, scale: 2, color: color); y += 20
            }
            y += 10
        }
        func field(_ id: String, _ label: String) {
            drawText(renderer, text: label, x: 16, y: y, scale: 1, color: (170, 187, 173)); y += 15
            textField(renderer, id, SDLBox(x: 16, y: y, width: 334, height: 34)); y += 46
        }
        func row(_ items: [(String, String, Bool)]) {
            let width = (334 - (items.count - 1) * 8) / items.count
            for (i, item) in items.enumerated() { button(renderer, item.0, item.1, SDLBox(x: 16 + i * (width + 8), y: y, width: width, height: 32), enabled: item.2) }
            y += 44
        }
        switch selectedTabID {
        case "map":
            paragraph("Minecraft \(selectedDatapack.version)")
            row([("version-prev", "Previous", selectedDatapack != vanillaDatapacks.first), ("version-next", "Next", selectedDatapack != vanillaDatapacks.last)])
            field("seed", "World seed")
            row([("paste-seed", "Paste", true), ("copy-seed", "Copy", true), ("random-seed", "Random", true)])
            field("y", "Sample Y (-64 to 316) / Overworld")
            row([("render", "Render", true)])
            paragraph("Go to coordinates")
            field("x", "X"); field("z", "Z")
            row([("go", "Go", true), ("origin", "Origin", true)])
            paragraph("Drag the map to pan. Scroll over the map to zoom. Click a marker for loot.")
        case "loot-search":
            paragraph("Loot search")
            field("search-x", "Start X"); field("search-z", "Start Z")
            row([("search-center", "Use map center", true)])
            field("radius", "Radius in blocks (1 to 10,000)")
            field("item", "Item / enchantment / potion")
            row([("search", searchRunning ? "Restart" : "Search", true), ("cancel-search", "Cancel", searchRunning)])
            paragraph(searchMessage)
            let progressWidth = searchProgress.total > 0 ? Int(334 * Double(searchProgress.done) / Double(searchProgress.total)) : 0
            fill(renderer, SDLBox(x: 16, y: y, width: 334, height: 6), (63, 72, 65))
            fill(renderer, SDLBox(x: 16, y: y, width: progressWidth, height: 6), (123, 192, 135)); y += 20
            row([("copy-results", "Copy results", !searchResults.isEmpty)])
            for (structure, containers) in searchGroups {
                paragraph("\(displayName(structure.structureID)) at \(structure.x), \(structure.z)", color: (161, 205, 255))
                for container in containers {
                    if let index = searchResults.firstIndex(of: container) { drawContainer(renderer, container, index: index, query: searchedItem, y: &y) }
                }
            }
            paragraph("Searches a square centered on X/Z. All words must match. Examples: diamond sword, enchant:sharpness 5, potion:healing.")
        case "loot":
            paragraph("Structure loot")
            field("filter", "Filter items")
            paragraph(lootMessage)
            row([("copy-results", "Copy loot", !filteredLoot.isEmpty)])
            if !fields["filter", default: ""].isEmpty && filteredLoot.isEmpty { paragraph("No containers match this filter.") }
            for (index, container) in filteredLoot.enumerated() { drawContainer(renderer, container, index: index, query: fields["filter", default: ""], y: &y) }
        case "biomes", "structures":
            let structures = selectedTabID == "structures"
            paragraph(structures ? "Structures" : "Biome colors")
            field(structures ? "structure-filter" : "biome-filter", "Filter by name")
            if structures { row([("all-structures", "Show all", true), ("no-structures", "Hide all", true)]) }
            row([("reset-colors", "Reset colors", true)])
            let ids = structures ? loadedStructureIDs : loadedBiomeIDs
            if ids.isEmpty { paragraph("Render a seed to load this list.") }
            if let id = selectedColorID, selectedColorIsStructure == structures {
                paragraph(displayName(id), color: (161, 205, 255))
                let color = structures ? structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id) : biomeColors[id] ?? resolvedBiomeColor(for: id)
                for (channel, value) in [("R", color.red), ("G", color.green), ("B", color.blue)] {
                    drawText(renderer, text: "\(channel) \(value)", x: 16, y: y + 10, scale: 2)
                    button(renderer, "channel:\(channel):-", "-", SDLBox(x: 100, y: y, width: 32, height: 32))
                    let track = SDLBox(x: 140, y: y, width: 168, height: 32)
                    button(renderer, "channel:\(channel):set", "", track)
                    fill(renderer, SDLBox(x: 148, y: y + 13, width: 152, height: 6), (86, 104, 91))
                    fill(renderer, SDLBox(x: 148 + Int(value) * 151 / 255, y: y + 7, width: 3, height: 18), (196, 219, 199))
                    button(renderer, "channel:\(channel):+", "+", SDLBox(x: 316, y: y, width: 34, height: 32)); y += 40
                }
            }
            let query = fields[structures ? "structure-filter" : "biome-filter", default: ""].lowercased()
            for id in ids where query.isEmpty || displayName(id).lowercased().contains(query) || id.lowercased().contains(query) {
                let color = structures ? structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id) : biomeColors[id] ?? resolvedBiomeColor(for: id)
                let nameX = structures ? 66 : 16
                let height = max(38, wrappedSDLLines(displayName(id), columns: structures ? 21 : 25).count * 18 + 16)
                if structures { button(renderer, "toggle:\(id)", enabledStructureSets.contains(id) ? "X" : "", SDLBox(x: 16, y: y + 3, width: 36, height: 32), selected: enabledStructureSets.contains(id)) }
                let box = SDLBox(x: nameX, y: y, width: 350 - nameX, height: height)
                button(renderer, "color:\(id)", "", box, selected: selectedColorID == id)
                fill(renderer, SDLBox(x: nameX + 8, y: y + 10, width: 10, height: 14), (color.red, color.green, color.blue))
                for (index, line) in wrappedSDLLines(displayName(id), columns: structures ? 21 : 25).enumerated() {
                    drawText(renderer, text: line, x: nameX + 24, y: y + 10 + index * 18, scale: 2)
                }
                y += height + 6
            }
        case "debug":
            paragraph("Advanced settings")
            paragraph("Generation threads: \(threadCount)")
            row([("threads-minus", "-", threadCount > 1), ("threads-plus", "+", threadCount < 32)])
            paragraph("Search threads: \(lootSearchThreadCount)")
            row([("search-threads-minus", "-", lootSearchThreadCount > 1), ("search-threads-plus", "+", lootSearchThreadCount < 4)])
            row([("llvm", "LLVM: \(enableDensityCompilation ? "On" : "Off")", true)])
            row([("apply-settings", "Apply settings", true)])
            paragraph(biomeGenerationStatus + "\n" + structureGenerationStatus)
            paragraph("Cached tiles: \(tiles.count)\nPending: \(pendingTileCount)")
            if let tile {
                paragraph("Last tile: \(tile.tileX), \(tile.tileZ)\nGeneration: \(formatDuration(tile.generationMilliseconds))")
                if let ms = tile.densityCompilationMilliseconds { paragraph("Density: \(tile.densityCompilationBackend ?? "unknown") \(formatDuration(ms))") }
            }
        case "about":
            paragraph("About DapperMap")
            paragraph("A free, open-source Minecraft seed mapper, powered by DPReader. Available for AppKit, Web and SDL.")
            row([("source", "Source", true), ("dpreader", "DPReader", true), ("license", "License", true)])
            paragraph("DapperMap is in beta. Generation and loot can sometimes differ from Minecraft. Report issues with the seed, version and coordinates.")
            paragraph("Known limitations: jungle temple and desert pyramid positions; some ocean ruin, end city and Nether ruined portal loot; ruined portal chest heights; explorer map loot resolution.")
            paragraph("GNU GPL v3 or later. Distributed without any warranty. Not an official Minecraft product. Not affiliated with Mojang or Microsoft.")
        default: break
        }
        contentHeight = y + scrollOffset - contentTop + 8
        if let container = revealContainer,
           let index = (selectedTabID == "loot-search" ? searchResults : filteredLoot).firstIndex(of: container),
           let control = controls.first(where: { $0.id == "container:\(index)" }) {
            scrollOffsets[selectedTabID] = max(0, scrollOffset + control.box.y - contentTop - 70)
            revealContainer = nil
        }
        scrollOffsets[selectedTabID] = min(scrollOffset, maxScroll)
        SDL_RenderSetClipRect(renderer, nil)
        if maxScroll > 0 {
            let trackHeight = contentBottom - contentTop
            let thumbHeight = max(24, trackHeight * trackHeight / max(1, contentHeight))
            let thumbY = contentTop + (trackHeight - thumbHeight) * scrollOffset / maxScroll
            fill(renderer, SDLBox(x: sidebarWidth - 10, y: contentTop, width: 4, height: trackHeight), (54, 64, 57))
            fill(renderer, SDLBox(x: sidebarWidth - 11, y: thumbY, width: 6, height: thumbHeight), (139, 162, 143))
        }
        fill(renderer, SDLBox(x: 0, y: contentBottom, width: sidebarWidth, height: 92), (25, 30, 27))
        button(renderer, "scroll-up", "Up", SDLBox(x: 16, y: contentBottom + 8, width: 72, height: 26), enabled: scrollOffset > 0, content: false, scale: 1)
        button(renderer, "scroll-down", "Down", SDLBox(x: 96, y: contentBottom + 8, width: 72, height: 26), enabled: scrollOffset < maxScroll, content: false, scale: 1)
        drawText(renderer, text: "X \(Int(centerX)) Z \(Int(centerZ))", x: 180, y: contentBottom + 12, scale: 1)
        drawText(renderer, text: String(format: "%.3g blocks / pixel", blocksPerPixel), x: 180, y: contentBottom + 24, scale: 1)
        for (index, line) in wrappedSDLLines(status, columns: 57).prefix(3).enumerated() {
            drawText(renderer, text: line, x: 16, y: contentBottom + 44 + index * 12, scale: 1)
        }
    }

    func drawContainer(_ renderer: OpaquePointer, _ container: MapLootPresentation, index: Int, query: String, y: inout Int) {
        for line in wrappedSDLLines("\(displayName(container.block))\nX \(container.x) Y \(container.y) Z \(container.z)", columns: 28) {
            drawText(renderer, text: line, x: 16, y: y, scale: 2, color: (248, 222, 160)); y += 20
        }
        button(renderer, "container:\(index)", "Show on map", SDLBox(x: 16, y: y + 4, width: 334, height: 30)); y += 44
        for item in container.items.isEmpty ? ["No resolved items"] : container.items {
            let matches = !query.isEmpty && LootSearchMatcher.matches(item: item, query: query)
            for line in wrappedSDLLines(displayName(item), columns: 26) {
                if matches { fill(renderer, SDLBox(x: 22, y: y - 2, width: 328, height: 20), (83, 72, 34)) }
                drawText(renderer, text: line, x: 28, y: y, scale: 2, color: matches ? (255, 226, 140) : (222, 227, 217)); y += 20
            }
            y += 6
        }
        y += 20
    }
    func displayName(_ id: String) -> String { id.replacingOccurrences(of: "minecraft:", with: "").replacingOccurrences(of: "_", with: " ") }
    func changeColor(_ action: String) {
        guard let id = selectedColorID else { return }
        let parts = action.split(separator: ":")
        let amount = parts.last == "+" ? 1 : -1
        let absolute = parts.last == "set" ? UInt8(clamping: (mouse.x - 148) * 255 / 151) : nil
        var color = selectedColorIsStructure ? structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id) : biomeColors[id] ?? resolvedBiomeColor(for: id)
        if parts[1] == "R" { color.red = absolute ?? UInt8(clamping: Int(color.red) + amount) }
        if parts[1] == "G" { color.green = absolute ?? UInt8(clamping: Int(color.green) + amount) }
        if parts[1] == "B" { color.blue = absolute ?? UInt8(clamping: Int(color.blue) + amount) }
        if selectedColorIsStructure { structureColors[id] = color }
        else { biomeColors[id] = color; needsTextureRebuild = true }
    }

    func fill(_ renderer: OpaquePointer, _ box: SDLBox, _ color: (UInt8, UInt8, UInt8)) {
        var rect = box.rect
        SDL_SetRenderDrawColor(renderer, color.0, color.1, color.2, 255); SDL_RenderFillRect(renderer, &rect)
    }
    func outline(_ renderer: OpaquePointer, _ box: SDLBox, _ color: (UInt8, UInt8, UInt8)) {
        var rect = box.rect
        SDL_SetRenderDrawColor(renderer, color.0, color.1, color.2, 255); SDL_RenderDrawRect(renderer, &rect)
    }
    func register(_ id: String, _ box: SDLBox, field: Bool = false, enabled: Bool = true, content: Bool = true) {
        let clip = SDLBox(x: 0, y: contentTop, width: sidebarWidth - 14, height: contentBottom - contentTop)
        controls.append(SDLControl(id: id, box: box, hitBox: content ? box.intersecting(clip) : box, field: field, enabled: enabled))
    }
    func button(_ renderer: OpaquePointer, _ id: String, _ title: String, _ box: SDLBox, enabled: Bool = true, selected: Bool = false, content: Bool = true, scale: Int = 2) {
        register(id, box, enabled: enabled, content: content)
        let hover = enabled && box.contains(mouse.x, mouse.y)
        fill(renderer, box, selected ? (62, 100, 73) : hover ? (72, 88, 76) : (47, 57, 50))
        outline(renderer, box, selected ? (148, 210, 163) : enabled ? (108, 129, 113) : (62, 73, 65))
        let actualScale = title.count * 6 * scale > box.width - 12 ? 1 : scale
        drawText(renderer, text: title, x: box.x + max(6, (box.width - title.count * 6 * actualScale) / 2), y: box.y + (box.height - 7 * actualScale) / 2, scale: actualScale, color: enabled ? (237, 241, 232) : (113, 126, 116))
    }
    func textField(_ renderer: OpaquePointer, _ id: String, _ box: SDLBox) {
        register(id, box, field: true)
        let focused = editor?.id == id
        fill(renderer, box, (18, 24, 20))
        outline(renderer, box, focused ? (153, 207, 255) : (116, 138, 121))
        if focused { outline(renderer, SDLBox(x: box.x + 1, y: box.y + 1, width: box.width - 2, height: box.height - 2), (153, 207, 255)) }
        let capacity = (box.width - 16) / 12
        let start = focused ? editor!.visibleStart(capacity: capacity) : 0
        let text = focused ? editor!.text : fields[id, default: ""]
        let visible = String(text.dropFirst(start).prefix(capacity))
        if focused, let edit = editor {
            let lower = max(start, edit.selection.lowerBound), upper = min(start + capacity, edit.selection.upperBound)
            if upper > lower { fill(renderer, SDLBox(x: box.x + 8 + (lower - start) * 12, y: box.y + 7, width: (upper - lower) * 12, height: 20), (54, 91, 133)) }
            if (SDL_GetTicks() / 500).isMultiple(of: 2) {
                fill(renderer, SDLBox(x: box.x + 8 + (edit.cursor - start) * 12, y: box.y + 7, width: 2, height: 20), (195, 226, 255))
            }
        }
        drawText(renderer, text: visible, x: box.x + 8, y: box.y + 10, scale: 2)
    }
    func drawText(_ renderer: OpaquePointer, text: String, x: Int, y: Int, scale: Int, color: (UInt8, UInt8, UInt8) = (238, 234, 218)) {
        var clip = SDL_Rect()
        SDL_RenderGetClipRect(renderer, &clip)
        let clipped = SDL_RenderIsClipEnabled(renderer) == SDL_TRUE
        if clipped && (y + 7 * scale <= clip.y || y >= clip.y + clip.h) && !text.contains("\n") { return }
        SDL_SetRenderDrawColor(renderer, color.0, color.1, color.2, 255)
        var cursor = x, lineY = y
        for char in text.uppercased() {
            if char == "\n" { cursor = x; lineY += 10 * scale; continue }
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
