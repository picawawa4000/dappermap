import XCTest
import DapperMapCore
import DapperMapEngine

final class DapperMapBaseTests: XCTestCase {
    func testSharedSidebarAllowsPlatformDebugFields() {
        let threads = SidebarField(id: "threads", label: "Threads", value: "4", kind: .integer(defaultValue: 4, range: 1...16))
        let sidebar = DapperMapBase.sidebar(extraDebugFields: [threads])
        XCTAssertEqual(sidebar.tabs.map(\.id), ["map", "biomes", "structures", "loot", "debug"])
        XCTAssertEqual(sidebar.tabs.first?.fields.map(\.id), ["seed", "y", "status", "biome-status", "structure-status"])
        XCTAssertEqual(sidebar.tabs.last?.fields, [threads])
    }

    func testSharedTooltipFormatsLootBeforeStructuresAndBiomes() {
        let loot = MapLootPresentation(
            block: "minecraft:chest", lootTable: "minecraft:test", x: 1, y: 2, z: 3,
            items: ["1 × minecraft:apple"]
        )
        let text = DapperMapBase.tooltipText(
            biome: "minecraft:plains", blockX: 9, blockZ: 10, structure: nil, container: loot
        )
        XCTAssertTrue(text.contains("minecraft:chest"))
        XCTAssertTrue(text.contains("1 × minecraft:apple"))
    }

    func testTileCoordinatesAreOrderedCenterFirst() {
        let coordinates = MapMath.centerFirstTileCoordinates(
            minTileX: -2,
            maxTileX: 2,
            minTileZ: -2,
            maxTileZ: 2,
            centerTileX: 0,
            centerTileZ: 0
        )
        XCTAssertEqual(coordinates.first?.tileX, 0)
        XCTAssertEqual(coordinates.first?.tileZ, 0)
        let rings = coordinates.map { max(abs($0.tileX), abs($0.tileZ)) }
        XCTAssertEqual(rings, rings.sorted())
    }
}
