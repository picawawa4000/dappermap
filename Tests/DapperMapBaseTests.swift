import XCTest
import DapperMapCore

final class DapperMapBaseTests: XCTestCase {
    func testSharedSidebarAllowsPlatformDebugFields() {
        let threads = SidebarField(id: "threads", label: "Threads", value: "4", kind: .integer(defaultValue: 4, range: 1...16))
        let sidebar = DapperMapBase.sidebar(extraDebugFields: [threads])
        XCTAssertEqual(sidebar.tabs.map(\.id), ["map", "biomes", "structures", "loot", "debug"])
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
}
