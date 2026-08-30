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

let mapSize = 256
let defaultSampleY: Int32 = 256
// Frequency-based structure sets (notably mineshafts) can have a tiny placement spacing. Give
// them a practical coarse-zoom cutoff without hiding them at normal map scales.
let minimumFrequencyStructureWorldSpacing = 256.0
let defaultBundlePath = "./Web/default-datapack.bundle.json.gz"
let runtimeDatapackPath = "./.dappermap/runtime/default-datapack"

public enum MapMath {
    public static let tileSize = 256

    public static func scaleKey(for blocksPerPixel: Double) -> Int {
        Int((max(0.125, blocksPerPixel) * 1024.0).rounded())
    }

    public static func tileBlocksPerPixel(for blocksPerPixel: Double) -> Double {
        let clamped = min(256.0, max(0.125, blocksPerPixel))
        return min(256.0, max(0.125, pow(2.0, floor(log2(clamped)))))
    }
}

struct DatapackBundle: Decodable {
    let files: [DatapackBundleFile]
}

struct DatapackBundleFile: Decodable {
    let path: String
    let contents: String?
    let base64Contents: String?
}

enum BrowserAppError: Error {
    case message(String)
}

func floorDivide(_ value: Int32, by divisor: Int32) -> Int32 {
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

struct ViewState: Equatable, Sendable {
    let centerX: Double
    let centerZ: Double
    let blocksPerPixel: Double
    let viewportWidth: Int
    let viewportHeight: Int
}

struct TileCacheKey: Hashable, Sendable {
    let seed: WorldSeed
    let scaleKey: Int
    let tileX: Int
    let tileZ: Int
}

/// A fused sampler has a fixed volume, so cache one for each tile shape and stride.
struct TileSamplerKey: Hashable, Sendable {
    let sampleWidth: Int32
    let sampleHeight: Int32
    let sampleYCount: Int32
    let sampleScale: Int32
}

public struct BiomeColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var cssHex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

}

struct CachedTile: Sendable {
    let width: Int
    let height: Int
    let palette: [String]
    let biomeIndices: [UInt16]
    let structurePoints: [StructurePoint]
    let structureMetrics: StructureProfilingMetrics
}

final class TileBiomeCache: @unchecked Sendable {
    let startX: Int32
    let startZ: Int32
    let scale: Int32
    let width: Int
    let height: Int
    let minY: Int32
    let yCount: Int
    private var columns: [Int64: [String]] = [:]
    private let columnSampler: (Int32, Int32) throws -> [String]

    init(startX: Int32, startZ: Int32, scale: Int32, width: Int, height: Int, minY: Int32, yCount: Int, columnSampler: @escaping (Int32, Int32) throws -> [String]) {
        self.startX = startX
        self.startZ = startZ
        self.scale = scale
        self.width = width
        self.height = height
        self.minY = minY
        self.yCount = yCount
        self.columnSampler = columnSampler
    }

    var usableMinX: Int32 { startX &+ 32 }
    var usableMaxX: Int32 { startX &+ (Int32(width) &- 1) &* scale &- 32 }
    var usableMinZ: Int32 { startZ &+ 32 }
    var usableMaxZ: Int32 { startZ &+ (Int32(height) &- 1) &* scale &- 32 }

    func biome(at position: PosInt3D) throws -> RegistryKey<Biome>? {
        // Structure validation is allowed to request arbitrary block coordinates. Resolve them
        // entirely from this tile's quart cache by snapping to the nearest cached X/Z column and
        // nearest quart Y sample; never fall back to WorldGenerator here.
        let x = min(max(floorDivide(position.x &- startX, by: scale), 0), Int32(width - 1))
        let z = min(max(floorDivide(position.z &- startZ, by: scale), 0), Int32(height - 1))
        let y = min(max(Int((Double(position.y - minY) / 4.0).rounded()), 0), yCount - 1)
        // DPReader bulk biome volumes are ordered z, then x, then y.
        let key = (Int64(x) << 32) | Int64(UInt32(bitPattern: z))
        let column: [String]
        if let cached = columns[key] {
            column = cached
        } else {
            let worldX = startX &+ x &* scale
            let worldZ = startZ &+ z &* scale
            column = try columnSampler(worldX, worldZ)
            columns[key] = column
        }
        return RegistryKey(referencing: column[y])
    }
}

struct TileAtlas {
    let seed: WorldSeed
    let scaleKey: Int
    let minTileX: Int
    let maxTileX: Int
    let minTileZ: Int
    let maxTileZ: Int
}

struct PendingTileJob: Sendable {
    let generation: Int
    let seed: WorldSeed
    let viewState: ViewState
    let tileBlocksPerPixel: Double
    let tileX: Int
    let tileZ: Int
    let sampleY: Int32
    let enabledStructureSets: Set<String>?
}

struct GeneratedTile: Sendable {
    let tile: CachedTile
    let generationMilliseconds: Double
    let densityCompilationMilliseconds: Double?
    let densityCompilationBackend: String?
}

struct StructurePoint: Hashable, Sendable {
    let setID: String
    let structureID: String
    let x: Int32
    let z: Int32
}

struct LootContainerPoint: Hashable, Sendable {
    let block: String
    let lootTable: String
    let x: Int32
    let y: Int32
    let z: Int32
    let loot: [String]
}

struct StructureQuery: Sendable {
    let seed: WorldSeed
    let minX: Int32
    let maxX: Int32
    let minZ: Int32
    let maxZ: Int32
    let enabledStructureSets: Set<String>
    let minimumSpacingBlocks: Double
}

struct StructureProfilingMetrics: Sendable {
    var totalMilliseconds = 0.0
    var samplingMilliseconds = 0.0
    var validationMilliseconds = 0.0
    var candidates = 0
    var accepted = 0
    var rejected = 0
    var cacheHits = 0
    var byStructureType: [String: StructureTypeProfilingMetrics] = [:]

    mutating func merge(_ other: Self) {
        totalMilliseconds += other.totalMilliseconds
        samplingMilliseconds += other.samplingMilliseconds
        validationMilliseconds += other.validationMilliseconds
        candidates += other.candidates
        accepted += other.accepted
        rejected += other.rejected
        cacheHits += other.cacheHits
        for (structureID, otherMetrics) in other.byStructureType {
            var metrics = byStructureType[structureID, default: StructureTypeProfilingMetrics()]
            metrics.starts += otherMetrics.starts
            metrics.totalMilliseconds += otherMetrics.totalMilliseconds
            byStructureType[structureID] = metrics
        }
    }
}

struct StructureTypeProfilingMetrics: Sendable {
    var starts = 0
    var totalMilliseconds = 0.0

    var averageMilliseconds: Double {
        starts == 0 ? 0.0 : totalMilliseconds / Double(starts)
    }
}

struct StructureQueryResult: Sendable {
    let points: [StructurePoint]
    let metrics: StructureProfilingMetrics
}

enum StructurePlacementKind: String, Decodable, Sendable {
    case randomSpread = "minecraft:random_spread"
    case concentricRings = "minecraft:concentric_rings"
}

struct StructureSetDescriptor: Sendable {
    let keyName: String
    let kind: StructurePlacementKind
    let spacing: Int32?
    let frequency: Double?
    let structureIDs: [String]
}

struct EncodedStructureSet: Decodable {
    let placement: EncodedStructurePlacement
    let structures: [EncodedWeightedStructure]
}

struct EncodedWeightedStructure: Decodable {
    let structure: String
}

struct EncodedStructurePlacement: Decodable {
    let type: StructurePlacementKind
    let spacing: Int32?
    let frequency: Double?
}

struct EncodedStructureDefinition: Decodable {
    let type: String
}

enum TileSamplingBackend: Sendable {
    case nestedWASM
    case scalar
}

struct TileProfilingMetrics {
    var generation = -1
    var sampledBiomeMilliseconds = 0.0
    var paletteMilliseconds = 0.0
    var rasterMilliseconds = 0.0
    var atlasMilliseconds = 0.0
    var viewportMilliseconds = 0.0
}

struct TileDebugMetrics {
    var tileX: Int?
    var tileZ: Int?
    var blocksPerPixel: Double?
    var generationMilliseconds: Double?
    var densityCompilationMilliseconds: Double?
    var densityCompilationBackend: String?
    var renderMilliseconds: Double?
}
