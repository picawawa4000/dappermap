import Foundation

/// Platform-neutral tile pixels and markers. A frontend decides whether this becomes a canvas,
/// a Core Graphics image, a texture, or something else.
public struct MapTilePresentation: Sendable {
    public let generation: Int
    public let seed: Int64
    public let scaleKey: Int
    public let tileX: Int
    public let tileZ: Int
    public let width: Int
    public let height: Int
    public let palette: [String]
    public let biomeIndices: [UInt16]
    public let structures: [MapStructurePresentation]
    public let generationMilliseconds: Double
    public let densityCompilationMilliseconds: Double?
    public let densityCompilationBackend: String?

    public init(generation: Int, seed: Int64, scaleKey: Int, tileX: Int, tileZ: Int, width: Int, height: Int, palette: [String], biomeIndices: [UInt16], structures: [MapStructurePresentation], generationMilliseconds: Double, densityCompilationMilliseconds: Double? = nil, densityCompilationBackend: String? = nil) {
        self.generation = generation
        self.seed = seed
        self.scaleKey = scaleKey
        self.tileX = tileX
        self.tileZ = tileZ
        self.width = width
        self.height = height
        self.palette = palette
        self.biomeIndices = biomeIndices
        self.structures = structures
        self.generationMilliseconds = generationMilliseconds
        self.densityCompilationMilliseconds = densityCompilationMilliseconds
        self.densityCompilationBackend = densityCompilationBackend
    }
}

public struct MapStructurePresentation: Hashable, Sendable {
    public let setID: String
    public let structureID: String
    public let x: Int32
    public let z: Int32

    public init(setID: String, structureID: String, x: Int32, z: Int32) {
        self.setID = setID
        self.structureID = structureID
        self.x = x
        self.z = z
    }
}

public struct MapLootPresentation: Hashable, Sendable {
    public let block: String
    public let lootTable: String
    public let x: Int32
    public let y: Int32
    public let z: Int32
    public let items: [String]

    public init(block: String, lootTable: String, x: Int32, y: Int32, z: Int32, items: [String]) {
        self.block = block
        self.lootTable = lootTable
        self.x = x
        self.y = y
        self.z = z
        self.items = items
    }
}

public struct MapTooltipPresentation: Equatable, Sendable {
    public let text: String
    public let screenX: Double
    public let screenY: Double

    public init(text: String, screenX: Double, screenY: Double) {
        self.text = text
        self.screenX = screenX
        self.screenY = screenY
    }
}

public struct SidebarField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text
        case integer(defaultValue: Int, range: ClosedRange<Int>)
    }

    public let id: String
    public let label: String
    public let value: String
    public let kind: Kind

    public init(id: String, label: String, value: String, kind: Kind) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
    }
}

public struct SidebarTab: Equatable, Sendable {
    public let id: String
    public let title: String
    public let heading: String
    public let fields: [SidebarField]

    public init(id: String, title: String, heading: String, fields: [SidebarField]) {
        self.id = id
        self.title = title
        self.heading = heading
        self.fields = fields
    }
}

public struct SidebarPresentation: Equatable, Sendable {
    public let tabs: [SidebarTab]

    public init(tabs: [SidebarTab]) {
        self.tabs = tabs
    }
}

/// The complete presentation seam between the shared app and a concrete frontend.
///
/// Browser code implements this with DOM/canvas calls. Native code implements it with AppKit and
/// Core Graphics. Generation scheduling is intentionally separate because workers and native
/// threads have different lifetime and cancellation rules.
@MainActor
public protocol DapperMapPlatform: AnyObject {
    func render(tile: MapTilePresentation)
    func render(tooltip: MapTooltipPresentation?)
    func render(sidebar: SidebarPresentation)
    func render(loot: [MapLootPresentation], message: String?, isError: Bool)
    func render(status: String, isError: Bool)
}

/// Platform-owned asynchronous execution. The shared app only describes work and receives a
/// result; it never assumes Web Workers, Dispatch, or a particular thread implementation.
public protocol DapperMapGenerationPlatform: Sendable {
    func generateTile(_ request: MapTileRequest) async throws -> MapTilePresentation
    func generateLoot(for structure: MapStructurePresentation, seed: Int64) async throws -> [MapLootPresentation]
}

public struct MapTileRequest: Sendable {
    public let generation: Int
    public let seed: Int64
    public let centerX: Double
    public let centerZ: Double
    public let blocksPerPixel: Double
    public let viewportWidth: Int
    public let viewportHeight: Int
    public let tileBlocksPerPixel: Double
    public let tileX: Int
    public let tileZ: Int
    public let sampleY: Int32
    public let enabledStructureSets: Set<String>?

    public init(generation: Int, seed: Int64, centerX: Double, centerZ: Double, blocksPerPixel: Double, viewportWidth: Int, viewportHeight: Int, tileBlocksPerPixel: Double, tileX: Int, tileZ: Int, sampleY: Int32 = 256, enabledStructureSets: Set<String>? = nil) {
        self.generation = generation
        self.seed = seed
        self.centerX = centerX
        self.centerZ = centerZ
        self.blocksPerPixel = blocksPerPixel
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.tileBlocksPerPixel = tileBlocksPerPixel
        self.tileX = tileX
        self.tileZ = tileZ
        self.sampleY = sampleY
        self.enabledStructureSets = enabledStructureSets
    }
}

/// Shared presentation policy and all user-facing map/sidebar text.
@MainActor
public final class DapperMapBase {
    private unowned let platform: any DapperMapPlatform

    public init(platform: any DapperMapPlatform) {
        self.platform = platform
    }

    public func renderSidebar(extraDebugFields: [SidebarField] = []) {
        platform.render(sidebar: Self.sidebar(extraDebugFields: extraDebugFields))
    }

    public func render(tile: MapTilePresentation) {
        platform.render(tile: tile)
    }

    public func render(status: String, isError: Bool = false) {
        platform.render(status: status, isError: isError)
    }

    public func render(loot: [MapLootPresentation], message: String? = nil, isError: Bool = false) {
        platform.render(loot: loot, message: message, isError: isError)
    }

    public func renderTooltip(
        biome: String?,
        blockX: Int,
        blockZ: Int,
        structure: MapStructurePresentation?,
        container: MapLootPresentation?,
        screenX: Double,
        screenY: Double
    ) {
        platform.render(tooltip: MapTooltipPresentation(
            text: Self.tooltipText(
                biome: biome,
                blockX: blockX,
                blockZ: blockZ,
                structure: structure,
                container: container
            ),
            screenX: screenX,
            screenY: screenY
        ))
    }

    public func hideTooltip() {
        platform.render(tooltip: nil)
    }

    public nonisolated static func sidebar(extraDebugFields: [SidebarField] = []) -> SidebarPresentation {
        SidebarPresentation(tabs: [
            SidebarTab(
                id: "map",
                title: "Map",
                heading: "Seed",
                fields: [SidebarField(id: "seed", label: "Seed Value", value: "0", kind: .text)]
            ),
            SidebarTab(id: "biomes", title: "Biomes", heading: "Biomes", fields: []),
            SidebarTab(id: "structures", title: "Structures", heading: "Structures", fields: []),
            SidebarTab(
                id: "loot",
                title: "Loot",
                heading: "Loot",
                fields: [SidebarField(
                    id: "loot-help",
                    label: "",
                    value: "Click a structure marker to reveal supported loot containers. Hover a container marker for its position and generated loot.",
                    kind: .text
                )]
            ),
            SidebarTab(
                id: "debug",
                title: "Debug",
                heading: "Tile Profiling",
                fields: extraDebugFields
            )
        ])
    }

    public nonisolated static func tooltipText(
        biome: String?,
        blockX: Int,
        blockZ: Int,
        structure: MapStructurePresentation?,
        container: MapLootPresentation?
    ) -> String {
        if let container {
            let loot = container.items.isEmpty ? "(No resolved items)" : container.items.joined(separator: "\n")
            return "\(container.block)\nX: \(container.x), Y: \(container.y), Z: \(container.z)\n\(loot)"
        }
        if let structure {
            return "Set: \(structure.setID)\nStructure: \(structure.structureID)\nX: \(structure.x), Z: \(structure.z)"
        }
        return "\(biome ?? "Loading biome…")\nX: \(blockX), Z: \(blockZ)"
    }
}
