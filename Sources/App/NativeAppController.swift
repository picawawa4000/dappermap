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
final class NativeAppController: NSObject, DapperMapPlatform, NativeMapViewDelegate {
    let window: NSWindow
    private let mapView = NativeMapView(frame: .zero)
    private let sidebar = NSView(frame: .zero)
    private let tabSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let panelHost = NSView(frame: .zero)
    private var panels: [String: NSView] = [:]
    private var orderedTabIDs: [String] = []
    private var seedInput: NSTextField?
    private var yInput: NSTextField?
    private var statusLabel: NSTextField?
    private var biomeList: NSStackView?
    private var structureList: NSStackView?
    private var biomeColors: [String: BiomeColor] = [:]
    private var structureColors: [String: BiomeColor] = [:]
    private var enabledStructureSets: Set<String> = []
    private var lootText: NSTextView?
    private var debugLabel: NSTextField?
    private var threadField: NSTextField?
    private var threadStepper: NSStepper?
    private lazy var commonBase = DapperMapBase(platform: self)
    private var scheduler: NativeGenerationPlatform?
    private var dataPackRoot: URL?
    private var threadCount: Int
    private var generation = 0
    private var renderTask: Task<Void, Never>?
    private var renderTimer: Timer?
    private var currentSeed: Int64?
    private var currentSampleY: Int32 = 256
    private var completedTiles = 0
    private var pendingTiles = 0
    private var awaitingFirstTileForSeed = false

    override init() {
        threadCount = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
    }

    func start() {
        commonBase.renderSidebar(extraDebugFields: [SidebarField(
            id: "threads",
            label: "Generation Threads",
            value: "\(threadCount)",
            kind: .integer(defaultValue: threadCount, range: 1...32)
        )])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        loadDatapack(threadCount: threadCount)
    }

    private func configureWindow() {
        window.title = "DapperMap"
        window.minSize = NSSize(width: 840, height: 560)
        let split = NSSplitView(frame: window.contentView?.bounds ?? .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        mapView.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(mapView)
        sidebar.widthAnchor.constraint(equalToConstant: 360).isActive = true
        mapView.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        window.contentView = split
        mapView.delegate = self
        mapView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mapFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: mapView
        )
    }

    @objc private func mapFrameDidChange() {
        guard currentSeed != nil else { return }
        scheduleRender()
    }

    func render(tile: MapTilePresentation) {
        guard tile.generation == generation, tile.seed == currentSeed else { return }
        mapView.install(tile: tile)
        completedTiles += 1
        pendingTiles = max(0, pendingTiles - 1)
        let wasAwaitingFirstTile = awaitingFirstTileForSeed
        awaitingFirstTileForSeed = false
        updateDebug(lastTile: tile)
        if pendingTiles == 0 {
            commonBase.render(
                status: "Rendered seed \(tile.seed) at Y=256, centered on (\(Int(mapView.centerX)), \(Int(mapView.centerZ))) with \(String(format: "%.2f", mapView.blocksPerPixel)) block(s) per pixel."
            )
        } else if wasAwaitingFirstTile {
            commonBase.render(status: "Generating remaining tiles…")
        }
    }

    func render(tooltip: MapTooltipPresentation?) {
        mapView.tooltip = tooltip
        mapView.needsDisplay = true
    }

    func render(sidebar presentation: SidebarPresentation) {
        sidebar.subviews.forEach { $0.removeFromSuperview() }
        panels.removeAll()
        orderedTabIDs = presentation.tabs.map(\.id)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            root.topAnchor.constraint(equalTo: sidebar.topAnchor),
            root.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])

        tabSelector.removeAllItems()
        tabSelector.addItems(withTitles: presentation.tabs.map(\.title))
        tabSelector.target = self
        tabSelector.action = #selector(tabChanged)
        tabSelector.widthAnchor.constraint(equalToConstant: 324).isActive = true
        root.addArrangedSubview(tabSelector)
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(panelHost)
        panelHost.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        panelHost.setContentHuggingPriority(.defaultLow, for: .vertical)

        for tab in presentation.tabs {
            let panel = makePanel(for: tab)
            panels[tab.id] = panel
            panel.translatesAutoresizingMaskIntoConstraints = false
            panelHost.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: panelHost.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: panelHost.trailingAnchor),
                panel.topAnchor.constraint(equalTo: panelHost.topAnchor)
            ])
            panel.isHidden = tab.id != presentation.tabs.first?.id
        }
    }

    func render(loot: [MapLootPresentation], message: String?, isError: Bool) {
        mapView.lootContainers = loot
        mapView.needsDisplay = true
        var sections: [String] = []
        if let message { sections.append(message) }
        sections += loot.map { container in
            let items = container.items.isEmpty ? "  No resolved items" : container.items.map { "  • \($0)" }.joined(separator: "\n")
            return "\(container.block) at (\(container.x), \(container.y), \(container.z))\n\(items)"
        }
        lootText?.string = sections.joined(separator: "\n\n")
        lootText?.textColor = isError ? .systemRed : .labelColor
        showTab("loot")
    }

    func render(status: String, isError: Bool) {
        statusLabel?.stringValue = status
        statusLabel?.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    func mapViewDidChangeView(_ mapView: NativeMapView) {
        scheduleRender()
    }

    func mapView(_ mapView: NativeMapView, hoverAt point: CGPoint) {
        let biome = mapView.biome(at: point)
        let container = mapView.loot(near: point)
        let structure = container == nil ? mapView.structure(near: point) : nil
        commonBase.renderTooltip(
            biome: biome.name,
            blockX: biome.x,
            blockZ: biome.z,
            structure: structure,
            container: container,
            screenX: point.x,
            screenY: point.y
        )
    }

    func mapView(_ mapView: NativeMapView, selectAt point: CGPoint) {
        if mapView.loot(near: point) != nil {
            showTab("loot")
            return
        }
        guard let structure = mapView.structure(near: point),
              let scheduler,
              let seed = currentSeed
        else { return }
        commonBase.render(loot: [], message: "Generating loot for \(structure.structureID)…")
        Task { [weak self] in
            do {
                let loot = try await scheduler.generateLoot(for: structure, seed: seed)
                guard let self, self.currentSeed == seed else { return }
                self.commonBase.render(
                    loot: loot,
                    message: loot.isEmpty ? "This structure has no supported loot containers." : nil
                )
            } catch {
                self?.commonBase.render(loot: [], message: "Could not generate structure loot: \(error)", isError: true)
            }
        }
    }

    private func makePanel(for tab: SidebarTab) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let heading = label(tab.heading, size: 18, bold: true)
        stack.addArrangedSubview(heading)

        switch tab.id {
        case "map":
            let seedLabel = label(tab.fields.first?.label ?? "Seed Value", size: 12, bold: true)
            stack.addArrangedSubview(seedLabel)
            let input = NSTextField(string: tab.fields.first?.value ?? "0")
            input.font = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            input.widthAnchor.constraint(equalToConstant: 324).isActive = true
            input.target = self
            input.action = #selector(renderSeed)
            stack.addArrangedSubview(input)
            seedInput = input
            stack.addArrangedSubview(label("Y (multiples of 4)", size: 12, bold: true))
            let yField = NSTextField(string: "256")
            yField.widthAnchor.constraint(equalToConstant: 324).isActive = true
            yField.target = self
            yField.action = #selector(renderSeed)
            stack.addArrangedSubview(yField)
            yInput = yField
            let button = NSButton(title: "Render", target: self, action: #selector(renderSeed))
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            button.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(button)
            let status = wrappingLabel("Loading Minecraft 1.21.11 datapack…")
            status.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(status)
            statusLabel = status
        case "biomes":
            let list = colorList()
            stack.addArrangedSubview(list.scroll)
            biomeList = list.stack
        case "structures":
            let list = colorList()
            stack.addArrangedSubview(list.scroll)
            structureList = list.stack
        case "loot":
            if let help = tab.fields.first?.value {
                let helpLabel = wrappingLabel(help)
                helpLabel.widthAnchor.constraint(equalToConstant: 324).isActive = true
                stack.addArrangedSubview(helpLabel)
            }
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 324, height: 420))
            text.isEditable = false
            text.drawsBackground = false
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
            scroll.documentView = text
            scroll.widthAnchor.constraint(equalToConstant: 324).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 420).isActive = true
            stack.addArrangedSubview(scroll)
            lootText = text
        case "debug":
            for field in tab.fields where field.id == "threads" {
                stack.addArrangedSubview(label(field.label, size: 12, bold: true))
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                let value = NSTextField(string: field.value)
                value.isEditable = false
                value.alignment = .right
                value.widthAnchor.constraint(equalToConstant: 48).isActive = true
                let stepper = NSStepper()
                if case .integer(let defaultValue, let range) = field.kind {
                    stepper.minValue = Double(range.lowerBound)
                    stepper.maxValue = Double(range.upperBound)
                    stepper.integerValue = defaultValue
                }
                stepper.target = self
                stepper.action = #selector(threadCountChanged)
                row.addArrangedSubview(value)
                row.addArrangedSubview(stepper)
                stack.addArrangedSubview(row)
                threadField = value
                threadStepper = stepper
            }
            let metrics = wrappingLabel("Waiting for a render")
            metrics.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
            metrics.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(metrics)
            debugLabel = metrics
        default:
            break
        }
        return stack
    }

    private func label(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        let base = NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        field.font = bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        return field
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont(name: "Georgia", size: 13) ?? .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func colorList() -> (scroll: NSScrollView, stack: NSStackView) {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 5
        list.widthAnchor.constraint(equalToConstant: 324).isActive = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = list
        scroll.widthAnchor.constraint(equalToConstant: 324).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 470).isActive = true
        return (scroll, list)
    }

    private func populateBiomeList(_ ids: [String]) {
        clear(colorList: biomeList)
        for id in ids.sorted() {
            let color = biomeColors[id] ?? resolvedBiomeColor(for: id)
            biomeColors[id] = color
            biomeList?.addArrangedSubview(colorRow(id: id, color: color, action: #selector(biomeColorChanged(_:))))
        }
        biomeList?.setFrameSize(NSSize(width: 324, height: max(470, ids.count * 27)))
        mapView.biomeColors = biomeColors
    }

    private func populateStructureList(_ ids: [String]) {
        clear(colorList: structureList)
        for id in ids.sorted() {
            let isNew = structureColors[id] == nil
            let color = structureColors[id] ?? defaultStructureColor(for: id) ?? resolvedBiomeColor(for: id)
            structureColors[id] = color
            if isNew {
                enabledStructureSets.insert(id)
            }
            structureList?.addArrangedSubview(structureRow(id: id, color: color))
        }
        structureList?.setFrameSize(NSSize(width: 324, height: max(470, ids.count * 27)))
        mapView.structureColors = structureColors
        mapView.enabledStructureSets = enabledStructureSets
    }

    private func clear(colorList: NSStackView?) {
        colorList?.arrangedSubviews.forEach {
            colorList?.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func colorRow(id: String, color: BiomeColor, action: Selector) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        let well = NSColorWell()
        well.color = NSColor(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
        well.identifier = NSUserInterfaceItemIdentifier(id)
        well.target = self
        well.action = action
        row.addArrangedSubview(well)
        let name = NSTextField(wrappingLabelWithString: id)
        name.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        name.widthAnchor.constraint(equalToConstant: 274).isActive = true
        row.addArrangedSubview(name)
        return row
    }

    private func structureRow(id: String, color: BiomeColor) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        let enabled = NSButton(checkboxWithTitle: "", target: self, action: #selector(structureEnabledChanged(_:)))
        enabled.state = enabledStructureSets.contains(id) ? .on : .off
        enabled.identifier = NSUserInterfaceItemIdentifier(id)
        row.addArrangedSubview(enabled)
        let well = NSColorWell()
        well.color = NSColor(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
        well.identifier = NSUserInterfaceItemIdentifier(id)
        well.target = self
        well.action = #selector(structureColorChanged(_:))
        row.addArrangedSubview(well)
        let name = NSTextField(wrappingLabelWithString: id)
        name.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        name.widthAnchor.constraint(equalToConstant: 245).isActive = true
        row.addArrangedSubview(name)
        return row
    }

    @objc private func biomeColorChanged(_ sender: NSColorWell) {
        guard let id = sender.identifier?.rawValue else { return }
        biomeColors[id] = biomeColor(from: sender.color)
        mapView.biomeColors = biomeColors
    }

    @objc private func structureColorChanged(_ sender: NSColorWell) {
        guard let id = sender.identifier?.rawValue else { return }
        structureColors[id] = biomeColor(from: sender.color)
        mapView.structureColors = structureColors
    }

    @objc private func structureEnabledChanged(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            enabledStructureSets.insert(id)
        } else {
            enabledStructureSets.remove(id)
        }
        mapView.enabledStructureSets = enabledStructureSets
    }

    private func biomeColor(from color: NSColor) -> BiomeColor {
        BiomeColor(
            red: UInt8((color.redComponent * 255).rounded()),
            green: UInt8((color.greenComponent * 255).rounded()),
            blue: UInt8((color.blueComponent * 255).rounded())
        )
    }

    @objc private func tabChanged() {
        guard tabSelector.indexOfSelectedItem >= 0,
              tabSelector.indexOfSelectedItem < orderedTabIDs.count
        else { return }
        showTab(orderedTabIDs[tabSelector.indexOfSelectedItem])
    }

    private func showTab(_ id: String) {
        panels.forEach { $0.value.isHidden = $0.key != id }
        if let index = orderedTabIDs.firstIndex(of: id) {
            tabSelector.selectItem(at: index)
        }
    }

    @objc private func renderSeed() {
        guard scheduler != nil else {
            commonBase.render(status: "Datapack is still loading.", isError: true)
            return
        }
        let raw = seedInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seed: Int64?
        if let signed = Int64(raw) {
            seed = signed
        } else if let unsigned = UInt64(raw) {
            seed = Int64(bitPattern: unsigned)
        } else {
            seed = nil
        }
        guard let seed else {
            commonBase.render(status: "Enter a valid 64-bit Minecraft seed.", isError: true)
            return
        }
        let rawY = Int32(yInput?.integerValue ?? 256)
        let sampleY = Int32((Double(min(316, max(-64, rawY)) / 4).rounded())) * 4
        yInput?.integerValue = Int(sampleY)
        if currentSeed != seed || currentSampleY != sampleY {
            commonBase.render(status: "Compiling density functions…")
            currentSeed = seed
            currentSampleY = sampleY
            awaitingFirstTileForSeed = true
            mapView.currentSeed = seed
            mapView.tiles.removeAll(keepingCapacity: true)
            mapView.tileImages.removeAll(keepingCapacity: true)
            mapView.lootContainers.removeAll()
        }
        scheduleRender(immediately: true)
    }

    @objc private func threadCountChanged() {
        guard let stepper = threadStepper else { return }
        let count = stepper.integerValue
        threadField?.stringValue = "\(count)"
        guard count != threadCount else { return }
        threadCount = count
        loadDatapack(threadCount: count)
    }

    private func loadDatapack(threadCount: Int) {
        generation += 1
        renderTask?.cancel()
        scheduler = nil
        commonBase.render(status: "Loading datapack for \(threadCount) generation thread\(threadCount == 1 ? "" : "s")…")
        do {
            dataPackRoot = try Self.findDatapackRoot()
        } catch {
            commonBase.render(status: "Could not locate the Minecraft datapack: \(error)", isError: true)
            return
        }
        guard let root = dataPackRoot else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.commonBase.render(status: "Compiling density functions…")
                let next = NativeGenerationPlatform(threadCount: threadCount)
                try await next.initialize(rootURL: root)
                let registry = await next.registryIDs()
                guard self.threadCount == threadCount else { return }
                self.scheduler = next
                self.populateBiomeList(registry.biomes)
                self.populateStructureList(registry.structures)
                self.commonBase.render(status: "Datapack ready. Enter a seed and click Render.")
                if self.currentSeed != nil { self.scheduleRender(immediately: true) }
            } catch {
                self.commonBase.render(status: "Failed to initialize DPReader: \(error)", isError: true)
            }
        }
    }

    private func scheduleRender(immediately: Bool = false) {
        renderTimer?.invalidate()
        let delay = immediately ? 0 : 0.08
        renderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.renderVisibleRegion() }
        }
    }

    private func renderVisibleRegion() {
        guard let scheduler, let seed = currentSeed else { return }
        generation += 1
        let activeGeneration = generation
        renderTask?.cancel()
        let width = max(1, Int(mapView.bounds.width.rounded()))
        let height = max(1, Int(mapView.bounds.height.rounded()))
        let bpp = mapView.blocksPerPixel
        let tileBPP = MapMath.tileBlocksPerPixel(for: bpp)
        let scaleKey = MapMath.scaleKey(for: tileBPP)
        mapView.currentScaleKey = scaleKey
        let span = Double(MapMath.tileSize) * tileBPP
        let worldStartX = mapView.centerX - Double(width) * bpp / 2
        let worldStartZ = mapView.centerZ - Double(height) * bpp / 2
        let worldEndX = worldStartX + Double(width) * bpp
        let worldEndZ = worldStartZ + Double(height) * bpp
        let minTileX = Int(floor(worldStartX / span))
        let maxTileX = Int(floor((worldEndX - 0.0001) / span))
        let minTileZ = Int(floor(worldStartZ / span))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / span))
        var requests: [MapTileRequest] = []
        for tileZ in minTileZ...maxTileZ {
            for tileX in minTileX...maxTileX {
                let key = NativeTileKey(seed: seed, scaleKey: scaleKey, tileX: tileX, tileZ: tileZ)
                guard mapView.tiles[key] == nil else { continue }
                requests.append(MapTileRequest(
                    generation: activeGeneration,
                    seed: seed,
                    centerX: mapView.centerX,
                    centerZ: mapView.centerZ,
                    blocksPerPixel: bpp,
                    viewportWidth: width,
                    viewportHeight: height,
                    tileBlocksPerPixel: tileBPP,
                    tileX: tileX,
                    tileZ: tileZ,
                    sampleY: Int32((Double(min(316, max(-64, yInput?.integerValue ?? 256)) / 4).rounded())) * 4,
                    enabledStructureSets: enabledStructureSets
                ))
            }
        }
        pendingTiles = requests.count
        completedTiles = 0
        mapView.needsDisplay = true
        if requests.isEmpty {
            commonBase.render(status: "Rendered seed \(seed) from the native tile cache.")
            return
        }
        commonBase.render(status: awaitingFirstTileForSeed
            ? "Compiling density functions…"
            : "Rendering seed \(seed) on \(threadCount) thread\(threadCount == 1 ? "" : "s"). Loading \(requests.count) tile(s)…")
        updateDebug(lastTile: nil)
        renderTask = Task { [weak self] in
            await withTaskGroup(of: Result<MapTilePresentation, Error>.self) { group in
                for request in requests {
                    group.addTask {
                        do { return .success(try await scheduler.generateTile(request)) }
                        catch { return .failure(error) }
                    }
                }
                for await result in group {
                    guard let self, activeGeneration == self.generation else { continue }
                    switch result {
                    case .success(let tile):
                        self.commonBase.render(tile: tile)
                    case .failure(let error):
                        self.pendingTiles = max(0, self.pendingTiles - 1)
                        self.commonBase.render(status: "Render failed: \(error)", isError: true)
                    }
                }
            }
        }
    }

    private func updateDebug(lastTile: MapTilePresentation?) {
        var lines = [
            "Threads: \(threadCount)",
            "Pending tiles: \(pendingTiles)",
            "Cached tiles: \(mapView.tiles.count)"
        ]
        if let tile = lastTile {
            lines += [
                "Last tile: (\(tile.tileX), \(tile.tileZ))",
                "Generation: \(String(format: "%.1f ms", tile.generationMilliseconds))"
            ]
            if let compilation = tile.densityCompilationMilliseconds,
               let backend = tile.densityCompilationBackend {
                lines.append("Density compilation (\(backend)): \(String(format: "%.1f ms", compilation))")
            }
        } else {
            lines.append("Last tile: waiting")
        }
        debugLabel?.stringValue = lines.joined(separator: "\n")
    }

    private static func findDatapackRoot() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DAPPERMAP_DATAPACK"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Data/1.21.11", isDirectory: true))
            candidates.append(resources.appendingPathComponent("1.21.11", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Data/1.21.11", isDirectory: true)
        )
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Data/1.21.11", isDirectory: true)
        )
        for candidate in candidates {
            let biomeDirectory = candidate.appendingPathComponent("data/minecraft/worldgen/biome", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: biomeDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        throw NativeAppError.message(
            "Set DAPPERMAP_DATAPACK to the 1.21.11 datapack directory, or run from the repository root."
        )
    }
}

private enum NativeAppError: Error {
    case message(String)
}

@MainActor
final class NativeAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NativeAppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        let controller = NativeAppController()
        self.controller = controller
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DapperMap", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DapperMap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }
}

/// Starts the retained AppKit/CoreGraphics frontend on Apple platforms.
@MainActor
public func launchCoreGraphicsApp() {
    let application = NSApplication.shared
    let delegate = NativeAppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
#endif
