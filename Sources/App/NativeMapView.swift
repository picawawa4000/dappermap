import DPReader
import DapperMapCore
import Foundation
import DapperMapEngine

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
#if !os(WASI) && canImport(AppKit)
@MainActor
protocol NativeMapViewDelegate: AnyObject {
    func mapViewDidChangeView(_ mapView: NativeMapView)
    func mapView(_ mapView: NativeMapView, hoverAt point: CGPoint)
    func mapView(_ mapView: NativeMapView, selectAt point: CGPoint)
}

struct NativeTileKey: Hashable {
    let seed: Int64
    let scaleKey: Int
    let tileX: Int
    let tileZ: Int
}

@MainActor
final class NativeMapView: NSView {
    weak var delegate: NativeMapViewDelegate?
    var centerX = 0.0
    var centerZ = 0.0
    var blocksPerPixel = 1.0
    var currentSeed: Int64?
    var currentScaleKey = MapMath.scaleKey(for: 1.0)
    var tiles: [NativeTileKey: MapTilePresentation] = [:]
    var tileImages: [NativeTileKey: CGImage] = [:]
    var biomeColors: [String: BiomeColor] = [:] {
        didSet { rebuildTileImages() }
    }
    var structureColors: [String: BiomeColor] = [:] {
        didSet { needsDisplay = true }
    }
    var enabledStructureSets: Set<String> = [] {
        didSet { needsDisplay = true }
    }
    var lootContainers: [MapLootPresentation] = []
    var tooltip: MapTooltipPresentation?

    private var trackingAreaReference: NSTrackingArea?
    private var dragStart: CGPoint?
    private var dragOrigin = CGPoint.zero
    private var dragged = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.969, green: 0.957, blue: 0.918, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor(calibratedRed: 0.925, green: 0.902, blue: 0.827, alpha: 1).cgColor)
        context.fill(bounds)
        context.interpolationQuality = .none

        guard let seed = currentSeed else {
            drawCenteredMessage("Enter a seed and click Render")
            return
        }

        let tileBPP = MapMath.tileBlocksPerPixel(for: blocksPerPixel)
        let worldStartX = centerX - bounds.width * blocksPerPixel / 2.0
        let worldStartZ = centerZ - bounds.height * blocksPerPixel / 2.0
        let tileWorldSpan = Double(MapMath.tileSize) * tileBPP

        for (key, image) in tileImages
        where key.seed == seed && key.scaleKey == currentScaleKey {
            let x = (Double(key.tileX * MapMath.tileSize) * tileBPP - worldStartX) / blocksPerPixel
            let z = (Double(key.tileZ * MapMath.tileSize) * tileBPP - worldStartZ) / blocksPerPixel
            let side = tileWorldSpan / blocksPerPixel
            context.draw(image, in: CGRect(x: x, y: z, width: side, height: side))
        }

        drawGrid(worldStartX: worldStartX, worldStartZ: worldStartZ, tileBPP: tileBPP)
        drawStructures(worldStartX: worldStartX, worldStartZ: worldStartZ)
        drawLoot(worldStartX: worldStartX, worldStartZ: worldStartZ)
        drawTooltip()
    }

    func install(tile: MapTilePresentation) {
        let key = NativeTileKey(
            seed: tile.seed,
            scaleKey: tile.scaleKey,
            tileX: tile.tileX,
            tileZ: tile.tileZ
        )
        tiles[key] = tile
        if let image = makeImage(for: tile) {
            tileImages[key] = image
        }
        needsDisplay = true
    }

    func visibleStructures() -> [MapStructurePresentation] {
        guard let seed = currentSeed else { return [] }
        return Array(Set(tiles.compactMap { key, tile in
            key.seed == seed && key.scaleKey == currentScaleKey
                ? tile.structures.filter { enabledStructureSets.contains($0.setID) }
                : []
        }.flatMap { $0 })).sorted {
            ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID)
        }
    }

    func biome(at point: CGPoint) -> (name: String?, x: Int, z: Int) {
        let world = worldPosition(at: point)
        let blockX = Int(floor(world.x))
        let blockZ = Int(floor(world.y))
        guard let seed = currentSeed else { return (nil, blockX, blockZ) }
        let tileBPP = MapMath.tileBlocksPerPixel(for: blocksPerPixel)
        let span = Double(MapMath.tileSize) * tileBPP
        let tileX = Int(floor(world.x / span))
        let tileZ = Int(floor(world.y / span))
        let key = NativeTileKey(seed: seed, scaleKey: currentScaleKey, tileX: tileX, tileZ: tileZ)
        guard let tile = tiles[key], tile.width > 0, tile.height > 0 else { return (nil, blockX, blockZ) }
        let originX = Double(tileX * MapMath.tileSize) * tileBPP
        let originZ = Double(tileZ * MapMath.tileSize) * tileBPP
        let outputX = min(max(Int(floor((world.x - originX) / tileBPP)), 0), MapMath.tileSize - 1)
        let outputZ = min(max(Int(floor((world.y - originZ) / tileBPP)), 0), MapMath.tileSize - 1)
        let sampleX = min(tile.width - 1, outputX * tile.width / MapMath.tileSize)
        let sampleZ = min(tile.height - 1, outputZ * tile.height / MapMath.tileSize)
        let paletteIndex = Int(tile.biomeIndices[sampleZ * tile.width + sampleX])
        return (tile.palette[paletteIndex], blockX, blockZ)
    }

    func structure(near point: CGPoint) -> MapStructurePresentation? {
        nearest(visibleStructures(), to: point, x: { Double($0.x) }, z: { Double($0.z) }, radius: 10)
    }

    func loot(near point: CGPoint) -> MapLootPresentation? {
        nearest(lootContainers, to: point, x: { Double($0.x) }, z: { Double($0.z) }, radius: 12)
    }

    override func scrollWheel(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let before = worldPosition(at: local)
        blocksPerPixel = min(256, max(0.125, blocksPerPixel * exp(event.scrollingDeltaY * 0.015)))
        let after = worldPosition(at: local)
        centerX += before.x - after.x
        centerZ += before.y - after.y
        currentScaleKey = MapMath.scaleKey(for: MapMath.tileBlocksPerPixel(for: blocksPerPixel))
        tooltip = nil
        needsDisplay = true
        delegate?.mapViewDidChangeView(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        dragOrigin = CGPoint(x: centerX, y: centerZ)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.x
        let dz = point.y - dragStart.y
        dragged = dragged || abs(dx) + abs(dz) > 3
        centerX = dragOrigin.x - dx * blocksPerPixel
        centerZ = dragOrigin.y - dz * blocksPerPixel
        tooltip = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragged {
            delegate?.mapViewDidChangeView(self)
        } else {
            delegate?.mapView(self, selectAt: point)
        }
        dragStart = nil
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.mapView(self, hoverAt: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        tooltip = nil
        needsDisplay = true
    }

    private func worldPosition(at point: CGPoint) -> CGPoint {
        CGPoint(
            x: centerX + (point.x - bounds.midX) * blocksPerPixel,
            y: centerZ + (point.y - bounds.midY) * blocksPerPixel
        )
    }

    private func screenPosition(x: Double, z: Double) -> CGPoint {
        CGPoint(
            x: bounds.midX + (x - centerX) / blocksPerPixel,
            y: bounds.midY + (z - centerZ) / blocksPerPixel
        )
    }

    private func nearest<T>(
        _ values: [T],
        to point: CGPoint,
        x: (T) -> Double,
        z: (T) -> Double,
        radius: CGFloat
    ) -> T? {
        values.compactMap { value -> (T, CGFloat)? in
            let screen = screenPosition(x: x(value), z: z(value))
            let distance = pow(screen.x - point.x, 2) + pow(screen.y - point.y, 2)
            return distance <= radius * radius ? (value, distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private func makeImage(for tile: MapTilePresentation) -> CGImage? {
        guard tile.width > 0, tile.height > 0 else { return nil }
        var bytes = [UInt8](repeating: 255, count: tile.width * tile.height * 4)
        let colors = tile.palette.map(biomeColor)
        // CoreGraphics draws a CGImage bottom-up inside this flipped NSView. Reverse the source
        // rows here so screen Y continues to mean increasing Minecraft Z across tile edges.
        for row in 0..<tile.height {
            for column in 0..<tile.width {
                let sourceIndex = row * tile.width + column
                let outputIndex = (tile.height - 1 - row) * tile.width + column
                let color = colors[Int(tile.biomeIndices[sourceIndex])]
                let offset = outputIndex * 4
                bytes[offset] = color.red
                bytes[offset + 1] = color.green
                bytes[offset + 2] = color.blue
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: tile.width,
            height: tile.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: tile.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func rebuildTileImages() {
        tileImages = Dictionary(uniqueKeysWithValues: tiles.compactMap { key, tile in
            makeImage(for: tile).map { (key, $0) }
        })
        needsDisplay = true
    }

    private func biomeColor(_ id: String) -> BiomeColor {
        biomeColors[id] ?? resolvedBiomeColor(for: id)
    }

    private func structureColor(_ id: String) -> NSColor {
        let color: BiomeColor
        if let override = structureColors[id] {
            color = override
        } else if let known = defaultStructureColor(for: id) {
            color = known
        } else {
            var hash: UInt32 = 2_166_136_261
            for byte in id.utf8 {
                hash ^= UInt32(byte)
                hash &*= 16_777_619
            }
            color = BiomeColor(
                red: UInt8(80 + (hash & 0x6f)),
                green: UInt8(80 + ((hash >> 8) & 0x6f)),
                blue: UInt8(80 + ((hash >> 16) & 0x6f))
            )
        }
        return NSColor(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    private func drawGrid(worldStartX: Double, worldStartZ: Double, tileBPP: Double) {
        let span = Double(MapMath.tileSize) * tileBPP
        let minTileX = Int(floor(worldStartX / span))
        let maxTileX = Int(ceil((worldStartX + bounds.width * blocksPerPixel) / span))
        let minTileZ = Int(floor(worldStartZ / span))
        let maxTileZ = Int(ceil((worldStartZ + bounds.height * blocksPerPixel) / span))
        let line = NSBezierPath()
        line.lineWidth = 1
        for x in minTileX...maxTileX {
            let screen = (Double(x) * span - worldStartX) / blocksPerPixel
            line.move(to: CGPoint(x: screen, y: 0))
            line.line(to: CGPoint(x: screen, y: bounds.height))
        }
        for z in minTileZ...maxTileZ {
            let screen = (Double(z) * span - worldStartZ) / blocksPerPixel
            line.move(to: CGPoint(x: 0, y: screen))
            line.line(to: CGPoint(x: bounds.width, y: screen))
        }
        NSColor(calibratedWhite: 0.12, alpha: 0.2).setStroke()
        line.stroke()

        let font = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 0.72)
        ]
        for z in minTileZ...maxTileZ {
            for x in minTileX...maxTileX {
                let point = CGPoint(
                    x: (Double(x) * span - worldStartX) / blocksPerPixel + 4,
                    y: (Double(z) * span - worldStartZ) / blocksPerPixel + 4
                )
                "\(Int(Double(x) * span)), \(Int(Double(z) * span))".draw(at: point, withAttributes: attributes)
            }
        }
    }

    private func drawStructures(worldStartX: Double, worldStartZ: Double) {
        let size = max(4, min(9, 6 / sqrt(blocksPerPixel)))
        for structure in visibleStructures() {
            let point = screenPosition(x: Double(structure.x), z: Double(structure.z))
            let outer = CGRect(x: point.x - size / 2 - 1, y: point.y - size / 2 - 1, width: size + 2, height: size + 2)
            NSColor.black.setFill()
            outer.fill()
            structureColor(structure.setID).setFill()
            outer.insetBy(dx: 1, dy: 1).fill()
        }
    }

    private func drawLoot(worldStartX: Double, worldStartZ: Double) {
        let size = max(5, min(11, 7 / sqrt(blocksPerPixel)))
        for container in lootContainers {
            let point = screenPosition(x: Double(container.x), z: Double(container.z))
            let outer = CGRect(x: point.x - size / 2 - 1.5, y: point.y - size / 2 - 1.5, width: size + 3, height: size + 3)
            NSColor.black.setFill()
            outer.fill()
            NSColor(calibratedRed: 1, green: 0.95, blue: 0.66, alpha: 1).setFill()
            outer.insetBy(dx: 1.5, dy: 1.5).fill()
        }
    }

    private func drawTooltip() {
        guard let tooltip else { return }
        let font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let maxSize = CGSize(width: min(380, bounds.width - 30), height: bounds.height - 30)
        let textRect = tooltip.text.boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        var origin = CGPoint(x: tooltip.screenX + 14, y: tooltip.screenY + 14)
        let boxSize = CGSize(width: ceil(textRect.width) + 16, height: ceil(textRect.height) + 14)
        origin.x = min(origin.x, bounds.width - boxSize.width - 8)
        origin.y = min(origin.y, bounds.height - boxSize.height - 8)
        let box = CGRect(origin: origin, size: boxSize)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.06, alpha: 0.94).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.45).setStroke()
        path.stroke()
        tooltip.text.draw(
            in: box.insetBy(dx: 8, dy: 7),
            withAttributes: attributes
        )
    }

    private func drawCenteredMessage(_ text: String) {
        let font = NSFont(name: "Georgia", size: 17) ?? .systemFont(ofSize: 17)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 0.8)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
#endif
