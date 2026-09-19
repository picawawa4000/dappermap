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

let vanillaBiomeDefaults: [String: BiomeColor] = [
    "minecraft:badlands": BiomeColor(red: 200, green: 120, blue: 60),
    "minecraft:bamboo_jungle": BiomeColor(red: 40, green: 170, blue: 70),
    "minecraft:basalt_deltas": BiomeColor(red: 60, green: 60, blue: 60),
    "minecraft:beach": BiomeColor(red: 230, green: 220, blue: 170),
    "minecraft:birch_forest": BiomeColor(red: 80, green: 170, blue: 80),
    "minecraft:cherry_grove": BiomeColor(red: 220, green: 160, blue: 180),
    "minecraft:cold_ocean": BiomeColor(red: 40, green: 80, blue: 180),
    "minecraft:crimson_forest": BiomeColor(red: 130, green: 20, blue: 20),
    "minecraft:dappled_forest": BiomeColor(red: 220, green: 110, blue: 0),
    "minecraft:dark_forest": BiomeColor(red: 20, green: 80, blue: 20),
    "minecraft:deep_cold_ocean": BiomeColor(red: 30, green: 70, blue: 150),
    "minecraft:deep_dark": BiomeColor(red: 20, green: 30, blue: 35),
    "minecraft:deep_frozen_ocean": BiomeColor(red: 90, green: 130, blue: 200),
    "minecraft:deep_lukewarm_ocean": BiomeColor(red: 50, green: 140, blue: 190),
    "minecraft:deep_ocean": BiomeColor(red: 20, green: 50, blue: 120),
    "minecraft:desert": BiomeColor(red: 235, green: 220, blue: 130),
    "minecraft:dripstone_caves": BiomeColor(red: 150, green: 120, blue: 90),
    "minecraft:end_barrens": BiomeColor(red: 170, green: 180, blue: 90),
    "minecraft:end_highlands": BiomeColor(red: 190, green: 200, blue: 110),
    "minecraft:end_midlands": BiomeColor(red: 180, green: 190, blue: 100),
    "minecraft:eroded_badlands": BiomeColor(red: 190, green: 110, blue: 55),
    "minecraft:flower_forest": BiomeColor(red: 60, green: 170, blue: 60),
    "minecraft:forest": BiomeColor(red: 34, green: 139, blue: 34),
    "minecraft:frozen_ocean": BiomeColor(red: 120, green: 170, blue: 230),
    "minecraft:frozen_peaks": BiomeColor(red: 210, green: 225, blue: 240),
    "minecraft:frozen_river": BiomeColor(red: 160, green: 200, blue: 255),
    "minecraft:grove": BiomeColor(red: 180, green: 220, blue: 180),
    "minecraft:ice_spikes": BiomeColor(red: 200, green: 230, blue: 255),
    "minecraft:jagged_peaks": BiomeColor(red: 200, green: 210, blue: 230),
    "minecraft:jungle": BiomeColor(red: 30, green: 150, blue: 50),
    "minecraft:lukewarm_ocean": BiomeColor(red: 60, green: 170, blue: 210),
    "minecraft:lush_caves": BiomeColor(red: 60, green: 150, blue: 80),
    "minecraft:mangrove_swamp": BiomeColor(red: 80, green: 100, blue: 50),
    "minecraft:meadow": BiomeColor(red: 90, green: 180, blue: 90),
    "minecraft:mushroom_fields": BiomeColor(red: 160, green: 80, blue: 160),
    "minecraft:nether_wastes": BiomeColor(red: 160, green: 60, blue: 40),
    "minecraft:ocean": BiomeColor(red: 30, green: 70, blue: 160),
    "minecraft:old_growth_birch_forest": BiomeColor(red: 60, green: 150, blue: 70),
    "minecraft:old_growth_pine_taiga": BiomeColor(red: 50, green: 110, blue: 90),
    "minecraft:old_growth_spruce_taiga": BiomeColor(red: 45, green: 100, blue: 85),
    "minecraft:pale_garden": BiomeColor(red: 140, green: 150, blue: 140),
    "minecraft:plains": BiomeColor(red: 120, green: 180, blue: 70),
    "minecraft:river": BiomeColor(red: 60, green: 110, blue: 200),
    "minecraft:savanna": BiomeColor(red: 180, green: 180, blue: 80),
    "minecraft:savanna_plateau": BiomeColor(red: 170, green: 170, blue: 70),
    "minecraft:small_end_islands": BiomeColor(red: 160, green: 170, blue: 85),
    "minecraft:snowy_beach": BiomeColor(red: 230, green: 240, blue: 250),
    "minecraft:snowy_plains": BiomeColor(red: 230, green: 240, blue: 250),
    "minecraft:snowy_slopes": BiomeColor(red: 220, green: 230, blue: 240),
    "minecraft:snowy_taiga": BiomeColor(red: 190, green: 210, blue: 220),
    "minecraft:soul_sand_valley": BiomeColor(red: 100, green: 80, blue: 60),
    "minecraft:sparse_jungle": BiomeColor(red: 50, green: 160, blue: 60),
    "minecraft:sulfur_caves": BiomeColor(red: 190, green: 180, blue: 55),
    "minecraft:stony_peaks": BiomeColor(red: 130, green: 130, blue: 130),
    "minecraft:stony_shore": BiomeColor(red: 120, green: 120, blue: 120),
    "minecraft:sunflower_plains": BiomeColor(red: 130, green: 190, blue: 75),
    "minecraft:swamp": BiomeColor(red: 70, green: 90, blue: 50),
    "minecraft:taiga": BiomeColor(red: 60, green: 120, blue: 100),
    "minecraft:the_end": BiomeColor(red: 128, green: 128, blue: 255),
    "minecraft:the_void": BiomeColor(red: 0, green: 0, blue: 0),
    "minecraft:warm_ocean": BiomeColor(red: 70, green: 200, blue: 220),
    "minecraft:warped_forest": BiomeColor(red: 30, green: 130, blue: 120),
    "minecraft:windswept_forest": BiomeColor(red: 70, green: 130, blue: 90),
    "minecraft:windswept_gravelly_hills": BiomeColor(red: 110, green: 110, blue: 110),
    "minecraft:windswept_hills": BiomeColor(red: 120, green: 120, blue: 120),
    "minecraft:windswept_savanna": BiomeColor(red: 160, green: 160, blue: 70),
    "minecraft:wooded_badlands": BiomeColor(red: 210, green: 130, blue: 70),
]

let vanillaStructureDefaults: [String: BiomeColor] = [
    "minecraft:ancient_city": BiomeColor(red: 69, green: 83, blue: 104),
    "minecraft:bastion_remnant": BiomeColor(red: 108, green: 67, blue: 52),
    "minecraft:buried_treasure": BiomeColor(red: 214, green: 177, blue: 74),
    "minecraft:desert_pyramid": BiomeColor(red: 222, green: 187, blue: 108),
    "minecraft:end_city": BiomeColor(red: 198, green: 130, blue: 210),
    "minecraft:fortress": BiomeColor(red: 163, green: 72, blue: 53),
    "minecraft:igloo": BiomeColor(red: 183, green: 225, blue: 238),
    "minecraft:jungle_pyramid": BiomeColor(red: 66, green: 132, blue: 73),
    "minecraft:mansion": BiomeColor(red: 76, green: 89, blue: 74),
    "minecraft:mineshaft": BiomeColor(red: 132, green: 93, blue: 56),
    "minecraft:mineshaft_mesa": BiomeColor(red: 181, green: 98, blue: 50),
    "minecraft:monument": BiomeColor(red: 68, green: 173, blue: 177),
    "minecraft:nether_fossil": BiomeColor(red: 151, green: 133, blue: 108),
    "minecraft:ocean_ruin_cold": BiomeColor(red: 105, green: 159, blue: 190),
    "minecraft:ocean_ruin_warm": BiomeColor(red: 198, green: 133, blue: 89),
    "minecraft:pillager_outpost": BiomeColor(red: 91, green: 76, blue: 61),
    "minecraft:ruined_portal": BiomeColor(red: 132, green: 68, blue: 143),
    "minecraft:shipwreck": BiomeColor(red: 125, green: 85, blue: 52),
    "minecraft:stronghold": BiomeColor(red: 130, green: 92, blue: 166),
    "minecraft:swamp_hut": BiomeColor(red: 87, green: 116, blue: 55),
    "minecraft:trail_ruins": BiomeColor(red: 174, green: 101, blue: 62),
    "minecraft:trial_chambers": BiomeColor(red: 86, green: 151, blue: 151),
    "minecraft:village_desert": BiomeColor(red: 229, green: 184, blue: 107),
    "minecraft:village_plains": BiomeColor(red: 198, green: 163, blue: 98),
    "minecraft:village_savanna": BiomeColor(red: 185, green: 137, blue: 65),
    "minecraft:village_snowy": BiomeColor(red: 202, green: 222, blue: 232),
    "minecraft:village_taiga": BiomeColor(red: 99, green: 133, blue: 102),
    "minecraft:woodland_mansion": BiomeColor(red: 65, green: 79, blue: 64)
]

public func defaultBiomeColor(for id: String) -> BiomeColor? {
    vanillaBiomeDefaults[id]
}

/// Shared deterministic palette used by every frontend when a biome has no user override.
public func resolvedBiomeColor(for id: String) -> BiomeColor {
    if let color = vanillaBiomeDefaults[id] { return color }
    var hash: UInt32 = 2_166_136_261
    for byte in id.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16_777_619
    }
    return BiomeColor(
        red: UInt8(64 + (hash & 0x7f)),
        green: UInt8(64 + ((hash >> 7) & 0x7f)),
        blue: UInt8(64 + ((hash >> 14) & 0x7f))
    )
}

public func defaultStructureColor(for id: String) -> BiomeColor? {
    vanillaStructureDefaults[id]
}
