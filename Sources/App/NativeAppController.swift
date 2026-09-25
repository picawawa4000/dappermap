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

private enum NativeTileGenerationResult: Sendable {
    case biome(Result<MapTilePresentation, Error>)
    case structures(Result<MapTileStructuresPresentation, Error>)
}

#if canImport(wasi_pthread)
import wasi_pthread
import WASILibc
#endif
#if !os(WASI) && canImport(AppKit)
@MainActor
final class NativeAppController: NSObject, DapperMapPlatform, NativeMapViewDelegate, NSTextFieldDelegate {
    let window: NSWindow
    private let mapView = NativeMapView(frame: .zero)
    private let sidebar = NSView(frame: .zero)
    private let tabSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let panelHost = NSView(frame: .zero)
    private var panels: [String: NSView] = [:]
    private var orderedTabIDs: [String] = []
    private var minecraftVersionInput: NSPopUpButton?
    private var seedInput: NSTextField?
    private var dimensionInput: NSPopUpButton?
    private var yInput: NSTextField?
    private var statusLabel: NSTextField?
    private var biomeGenerationStatusLabel: NSTextField?
    private var structureGenerationStatusLabel: NSTextField?
    private var biomeList: NSStackView?
    private var structureList: NSStackView?
    private var biomeColors: [String: BiomeColor] = [:]
    private var structureColors: [String: BiomeColor] = [:]
    private var enabledStructureSets: Set<String> = []
    private var lootFilterInput: NSTextField?
    private var lootText: NSTextView?
    private var lootContainers: [MapLootPresentation] = []
    private var lootMessage: String?
    private var lootMessageIsError = false
    private var lootSearchXInput: NSTextField?
    private var lootSearchZInput: NSTextField?
    private var lootSearchRadiusInput: NSTextField?
    private var lootSearchItemInput: NSTextField?
    private var lootSearchText: NSTextView?
    private var lootSearchProgress: NSProgressIndicator?
    private var lootSearchCurrentLabel: NSTextField?
    private var lootSearchResults: [MapLootPresentation] = []
    private var lootSearchGroups: [(structure: MapStructurePresentation, containers: [MapLootPresentation])] = []
    private var lootSearchRequest = 0
    private var lootSearchTask: Task<Void, Never>?
    private var debugLabel: NSTextField?
    private var threadField: NSTextField?
    private var threadStepper: NSStepper?
    private lazy var commonBase = DapperMapBase(platform: self)
    private var scheduler: NativeGenerationPlatform?
    private var dataPackRoot: URL?
    private var selectedDatapack = defaultVanillaDatapack
    private var threadCount: Int
    private var lootSearchThreadCount = 1
    private var enableDensityCompilation = ProcessInfo.processInfo.environment["DAPPERMAP_ENABLE_LLVM"] == "1"
    private var generation = 0
    private var renderTask: Task<Void, Never>?
    private var renderTimer: Timer?
    private var currentSeed: Int64?
    private var currentSampleY: Int32 = 256
    private var currentDimensionID = "minecraft:overworld"
    private var completedTiles = 0
    private var pendingTiles = 0
    private var completedStructureTiles = 0
    private var pendingStructureTiles = 0
    private var deferredStructureResults: [NativeTileKey: MapTileStructuresPresentation] = [:]
    private var tileGenerationMode: MapTileGenerationMode = .combined
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
        ), SidebarField(
            id: "loot-search-threads",
            label: "Loot Search Threads",
            value: "\(lootSearchThreadCount)",
            kind: .integer(defaultValue: lootSearchThreadCount, range: 1...4)
        ), SidebarField(
            id: "tile-generation-mode",
            label: "Tile Scheduling",
            value: tileGenerationMode.title,
            kind: .text
        ), SidebarField(
            id: "llvm",
            label: "LLVM Density Compilation",
            value: enableDensityCompilation ? "On" : "Off",
            kind: .text
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
        biomeGenerationStatusLabel?.stringValue = "Biomes: \(completedTiles)/\(completedTiles + pendingTiles) tile(s) ready."
        structureGenerationStatusLabel?.stringValue = "Structures: \(completedTiles)/\(completedTiles + pendingTiles) tile(s) ready."
        if pendingTiles == 0 {
            commonBase.render(
                status: "Rendered seed \(tile.seed) at Y=\(currentSampleY), centered on (\(Int(mapView.centerX)), \(Int(mapView.centerZ))) with \(String(format: "%.2f", mapView.blocksPerPixel)) block(s) per pixel."
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
        lootContainers = loot
        lootMessage = message
        lootMessageIsError = isError
        renderLootText()
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
            stack.addArrangedSubview(label("Minecraft Version", size: 15, bold: true))
            let versionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
            versionPicker.addItems(withTitles: vanillaDatapacks.map(\.version))
            versionPicker.selectItem(withTitle: selectedDatapack.version)
            versionPicker.widthAnchor.constraint(equalToConstant: 324).isActive = true
            versionPicker.target = self
            versionPicker.action = #selector(minecraftVersionChanged)
            stack.addArrangedSubview(versionPicker)
            minecraftVersionInput = versionPicker
            let seedField = tab.fields.first { $0.id == "seed" }
            let dimensionField = tab.fields.first { $0.id == "dimension" }
            let yFieldPresentation = tab.fields.first { $0.id == "y" }
            let seedLabel = label(seedField?.label ?? "Seed", size: 15, bold: true)
            stack.addArrangedSubview(seedLabel)
            let input = NSTextField(string: seedField?.value ?? "0")
            input.isEditable = true
            input.isSelectable = true
            input.font = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            input.widthAnchor.constraint(equalToConstant: 324).isActive = true
            input.target = self
            input.action = #selector(renderSeed)
            stack.addArrangedSubview(input)
            seedInput = input
            let seedActions = NSStackView()
            seedActions.orientation = .horizontal
            seedActions.distribution = .fillEqually
            seedActions.spacing = 8
            let randomButton = NSButton(title: "Random Seed", target: self, action: #selector(randomSeed))
            let renderButton = NSButton(title: "Render", target: self, action: #selector(renderSeed))
            renderButton.keyEquivalent = "\r"
            seedActions.addArrangedSubview(randomButton)
            seedActions.addArrangedSubview(renderButton)
            seedActions.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(seedActions)
            stack.addArrangedSubview(label(dimensionField?.label ?? "Dimension", size: 15, bold: true))
            let dimensionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
            dimensionPicker.addItem(withTitle: dimensionField?.value ?? "minecraft:overworld")
            dimensionPicker.widthAnchor.constraint(equalToConstant: 324).isActive = true
            dimensionPicker.target = self
            dimensionPicker.action = #selector(renderSeed)
            stack.addArrangedSubview(dimensionPicker)
            dimensionInput = dimensionPicker
            stack.addArrangedSubview(label(yFieldPresentation?.label ?? "Y", size: 15, bold: true))
            stack.addArrangedSubview(label("Multiples of 4", size: 11, bold: false))
            let yField = NSTextField(string: yFieldPresentation?.value ?? "256")
            yField.widthAnchor.constraint(equalToConstant: 324).isActive = true
            yField.target = self
            yField.action = #selector(renderSeed)
            stack.addArrangedSubview(yField)
            yInput = yField
            stack.addArrangedSubview(label("Status", size: 15, bold: true))
            let status = wrappingLabel("Loading Minecraft \(selectedDatapack.version) datapack…")
            status.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(status)
            statusLabel = status
            let biomeStatus = wrappingLabel("Biomes: waiting.")
            biomeStatus.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(biomeStatus)
            biomeGenerationStatusLabel = biomeStatus
            let structureStatus = wrappingLabel("Structures: waiting for biomes.")
            structureStatus.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(structureStatus)
            structureGenerationStatusLabel = structureStatus
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
            stack.addArrangedSubview(label("Filter item", size: 12, bold: true))
            let filter = NSTextField()
            filter.placeholderString = "e.g. diamond"
            filter.target = self
            filter.action = #selector(lootFilterChanged(_:))
            filter.delegate = self
            filter.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(filter)
            lootFilterInput = filter
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
        case "loot-search":
            if let help = tab.fields.first?.value {
                let helpLabel = wrappingLabel(help)
                helpLabel.widthAnchor.constraint(equalToConstant: 324).isActive = true
                stack.addArrangedSubview(helpLabel)
            }
            let fields: [(String, String, ReferenceWritableKeyPath<NativeAppController, NSTextField?>)] = [
                ("Start X", "0", \NativeAppController.lootSearchXInput),
                ("Start Z", "0", \NativeAppController.lootSearchZInput),
                ("Radius", "1000", \NativeAppController.lootSearchRadiusInput),
                ("Item or descriptor", "", \NativeAppController.lootSearchItemInput)
            ]
            for (name, value, keyPath) in fields {
                stack.addArrangedSubview(label(name, size: 12, bold: true))
                let field = NSTextField(string: value)
                field.widthAnchor.constraint(equalToConstant: 324).isActive = true
                stack.addArrangedSubview(field)
                self[keyPath: keyPath] = field
            }
            let searchLocation = NSButton(title: "Use Map Center", target: self, action: #selector(useMapCenterForLootSearch))
            searchLocation.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(searchLocation)
            let searchActions = NSStackView()
            searchActions.orientation = .horizontal
            searchActions.distribution = .fillEqually
            searchActions.spacing = 8
            searchActions.addArrangedSubview(NSButton(title: "Search Chests", target: self, action: #selector(searchLoot)))
            searchActions.addArrangedSubview(NSButton(title: "Cancel", target: self, action: #selector(cancelLootSearch)))
            searchActions.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(searchActions)
            let progress = NSProgressIndicator()
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = 0
            progress.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(progress)
            lootSearchProgress = progress
            let current = wrappingLabel("Waiting to search.")
            current.widthAnchor.constraint(equalToConstant: 324).isActive = true
            stack.addArrangedSubview(current)
            lootSearchCurrentLabel = current
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 324, height: 360))
            text.isEditable = false
            text.drawsBackground = false
            scroll.documentView = text
            scroll.widthAnchor.constraint(equalToConstant: 324).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 360).isActive = true
            stack.addArrangedSubview(scroll)
            lootSearchText = text
        case "about":
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 324, height: 560))
            text.isEditable = false
            text.isSelectable = true
            text.isAutomaticLinkDetectionEnabled = true
            text.drawsBackground = false
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: 324, height: CGFloat.greatestFiniteMagnitude)
            text.maxSize = NSSize(width: 324, height: CGFloat.greatestFiniteMagnitude)
            text.font = NSFont.systemFont(ofSize: 13)
            text.string = Self.aboutText
            scroll.documentView = text
            scroll.widthAnchor.constraint(equalToConstant: 324).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 560).isActive = true
            stack.addArrangedSubview(scroll)
        case "debug":
            stack.addArrangedSubview(label("Advanced Settings", size: 16, bold: true))
            for field in tab.fields where field.id == "threads" || field.id == "loot-search-threads" {
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
                stepper.identifier = NSUserInterfaceItemIdentifier(field.id)
                stepper.target = self
                stepper.action = #selector(advancedThreadCountChanged(_:))
                row.addArrangedSubview(value)
                row.addArrangedSubview(stepper)
                stack.addArrangedSubview(row)
                if field.id == "threads" {
                    threadField = value
                    threadStepper = stepper
                }
            }
            let llvm = NSButton(checkboxWithTitle: "LLVM Density Compilation", target: self, action: #selector(llvmCompilationChanged(_:)))
            llvm.state = enableDensityCompilation ? .on : .off
            stack.addArrangedSubview(llvm)
            stack.addArrangedSubview(label("Tile Scheduling", size: 12, bold: true))
            let scheduling = NSPopUpButton()
            for mode in MapTileGenerationMode.allCases { scheduling.addItem(withTitle: mode.title) }
            scheduling.selectItem(at: MapTileGenerationMode.allCases.firstIndex(of: tileGenerationMode) ?? 0)
            scheduling.target = self
            scheduling.action = #selector(tileGenerationModeChanged(_:))
            stack.addArrangedSubview(scheduling)
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

    private static let aboutText = """
    About DapperMap

    In sum, DapperMap is yet another Minecraft seed mapper. However, it has some important features that differentiate it from other present seed mappers:

    • It is fully free and open-source: you can see all of the source code at https://github.com/picawawa4000/dappermap.
    • It has full support for datapacks (in fact, the underlying library, DPReader (https://github.com/picawawa4000/dpreader-swift), only works when fed Minecraft's default datapack). (As of writing this, uploading datapacks is not supported, but it would be a triviality to implement.)
    • It is available both as a webapp (via SwiftWASM and JavaScriptKit) and as a native app for macOS (via AppKit). (There is technically cross-platform support via SDL, but it doesn't look very nice right now, so do not consider it done yet.) The native app is much faster than the webapp; give it a try if you can.
    • It supports viewing structure loot: you can click on a structure and the map will display all of its chests, along with their loot. Additionally, searching for loot is supported: you can input a location, radius, and item, and the app will find all instances of that item in that radius.

    Limitations

    DapperMap is currently in beta. As such, while it is usually quite accurate, it can be wrong sometimes. The following is a list of known issues:

    • The following structures are sometimes not positioned correctly: jungle temples, desert pyramids.
    • The following structures display the wrong loot for some blocks: ocean ruins, end cities, ruined portals in the Nether.
    • The following structures display the correct loot and chest position, except that chests show up at the bottom of the world: ruined portals.
    • Explorer maps can crash loot resolution.

    If you ever run into any other issues using DapperMap, report them in the GitHub issue tracker. Include the exact seed, version, conditions, and coordinates/structure (where applicable) that caused the issue.

    Disclaimer

    This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You may find a copy at https://github.com/picawawa4000/dappermap/blob/main/LICENCE.txt.

    NOT AN OFFICIAL MINECRAFT PRODUCT. NOT AFFILIATED WITH OR ENDORSED BY MOJANG AB OR MICROSOFT.
    """

    @objc fileprivate func showAboutPopup() {
        let alert = NSAlert()
        alert.messageText = "About DapperMap"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 700))
        text.isEditable = false
        text.isSelectable = true
        text.isAutomaticLinkDetectionEnabled = true
        text.string = Self.aboutText
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Source")
        alert.addButton(withTitle: "DPReader")
        alert.addButton(withTitle: "License")
        alert.addButton(withTitle: "Close")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(URL(string: "https://github.com/picawawa4000/dappermap")!)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(URL(string: "https://github.com/picawawa4000/dpreader-swift")!)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: "https://github.com/picawawa4000/dappermap/blob/main/LICENCE.txt")!)
        default: break
        }
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

    private func populateDimensionPicker(_ ids: [String]) {
        let selectedID = dimensionInput?.titleOfSelectedItem ?? "minecraft:overworld"
        let availableIDs = ids.isEmpty ? ["minecraft:overworld"] : ids
        dimensionInput?.removeAllItems()
        dimensionInput?.addItems(withTitles: availableIDs)
        dimensionInput?.selectItem(withTitle: availableIDs.contains(selectedID) ? selectedID : availableIDs[0])
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

    @objc private func lootFilterChanged(_ sender: NSTextField) {
        renderLootText()
    }

    @objc private func searchLoot() {
        guard let scheduler, let seed = currentSeed else {
            renderLootSearchText("Render a seed before searching.")
            return
        }
        guard let x = Int32(lootSearchXInput?.stringValue ?? ""),
              let z = Int32(lootSearchZInput?.stringValue ?? ""),
              let radius = Int32(lootSearchRadiusInput?.stringValue ?? "") else {
            renderLootSearchText("Start X, Start Z, and radius must be whole numbers.")
            return
        }
        let query = LootSearchQuery(
            startX: x,
            startZ: z,
            radius: radius,
            itemQuery: lootSearchItemInput?.stringValue ?? "",
            dimensionID: currentDimensionID
        )
        renderLootSearchText("Searching chests…")
        lootSearchTask?.cancel()
        lootSearchRequest += 1
        let request = lootSearchRequest
        lootSearchResults = []
        lootSearchGroups = []
        lootSearchProgress?.maxValue = 1
        lootSearchProgress?.doubleValue = 0
        lootSearchCurrentLabel?.stringValue = "Finding structures…"
        lootSearchTask = Task { [weak self] in
            do {
                let results = try await scheduler.searchLoot(query, seed: seed) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, request == self.lootSearchRequest else { return }
                        self.applyLootSearch(progress)
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, request == self.lootSearchRequest else { return }
                    let header = results.isEmpty ? "No matching chests found." : "Found \(results.count) matching chest\(results.count == 1 ? "" : "s")."
                    self.lootSearchCurrentLabel?.stringValue = "Done."
                    self.renderLootSearchGroups(header)
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { [weak self] in self?.renderLootSearchText("Loot search failed: \(error)") }
            }
        }
    }

    private func renderLootSearchText(_ text: String) {
        guard let lootSearchText else { return }
        let query = lootSearchItemInput?.stringValue ?? ""
        let normalFont = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let value = String(line)
            let item = value.hasPrefix("    • ") ? String(value.dropFirst(6)) : nil
            let matches = item.map { LootSearchMatcher.matches(item: $0, query: query) } ?? false
            result.append(NSAttributedString(
                string: value + (index + 1 < lines.count ? "\n" : ""),
                attributes: [
                    .font: normalFont,
                    .foregroundColor: matches ? NSColor.black : NSColor.labelColor,
                    .backgroundColor: matches ? NSColor.systemYellow.withAlphaComponent(0.6) : NSColor.clear
                ]
            ))
        }
        lootSearchText.textStorage?.setAttributedString(result)
    }

    private func applyLootSearch(_ progress: LootSearchProgress) {
        lootSearchResults.append(contentsOf: progress.matches)
        if let structure = progress.currentStructure, !progress.matches.isEmpty {
            lootSearchGroups.append((structure, progress.matches))
        }
        lootSearchProgress?.maxValue = Double(max(1, progress.totalStructures))
        lootSearchProgress?.doubleValue = Double(progress.structuresScanned)
        if let structure = progress.currentStructure {
            lootSearchCurrentLabel?.stringValue = "Generating: \(structure.structureID) at (\(structure.x), \(structure.z)) — \(progress.structuresScanned)/\(progress.totalStructures)"
        }
        renderLootSearchGroups("Found \(lootSearchResults.count) matching chest\(lootSearchResults.count == 1 ? "" : "s") so far.")
    }

    private func renderLootSearchGroups(_ message: String) {
        let groups = lootSearchGroups.map { group in
            "\(group.structure.structureID) at (\(group.structure.x), \(group.structure.z)) — \(group.containers.count) matching chest\(group.containers.count == 1 ? "" : "s")\n" + group.containers.map { container in
                "  \(container.block) at (\(container.x), \(container.y), \(container.z))\n" + container.items.map { "    • \($0)" }.joined(separator: "\n")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        renderLootSearchText(groups.isEmpty ? message : "\(message)\n\n\(groups)")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === lootFilterInput else { return }
        renderLootText()
    }

    private func renderLootText() {
        guard let lootText else { return }
        let filter = lootFilterInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let matchingContainers = filter.isEmpty
            ? lootContainers
            : lootContainers.filter { container in
                container.items.contains { $0.lowercased().contains(filter) }
            }

        let normalFont = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        if let lootMessage {
            result.append(NSAttributedString(
                string: "\(lootMessage)\n\n",
                attributes: [.font: normalFont, .foregroundColor: lootMessageIsError ? NSColor.systemRed : NSColor.labelColor]
            ))
        }
        if !filter.isEmpty && matchingContainers.isEmpty {
            result.append(NSAttributedString(
                string: "No containers contain \(lootFilterInput?.stringValue ?? filter).",
                attributes: [.font: normalFont, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        for (containerIndex, container) in matchingContainers.enumerated() {
            if containerIndex > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(
                string: "\(container.block) at (\(container.x), \(container.y), \(container.z))\n",
                attributes: [.font: normalFont, .foregroundColor: NSColor.labelColor]
            ))
            if container.items.isEmpty {
                result.append(NSAttributedString(
                    string: "  No resolved items",
                    attributes: [.font: normalFont, .foregroundColor: NSColor.secondaryLabelColor]
                ))
            }
            for item in container.items {
                let isMatch = !filter.isEmpty && item.lowercased().contains(filter)
                result.append(NSAttributedString(
                    string: "  • \(item)\n",
                    attributes: [
                        .font: normalFont,
                        .foregroundColor: isMatch ? NSColor.black : NSColor.labelColor,
                        .backgroundColor: isMatch ? NSColor.systemYellow.withAlphaComponent(0.6) : NSColor.clear
                    ]
                ))
            }
        }
        lootText.textStorage?.setAttributedString(result)
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
        let seed = MapMath.parseWorldSeed(raw)
        guard let seed else {
            commonBase.render(status: "Enter a valid 64-bit Minecraft seed.", isError: true)
            return
        }
        let rawY = Int32(yInput?.integerValue ?? 256)
        let sampleY = Int32((Double(min(316, max(-64, rawY)) / 4).rounded())) * 4
        let dimensionID = dimensionInput?.titleOfSelectedItem ?? "minecraft:overworld"
        yInput?.integerValue = Int(sampleY)
        if currentSeed != seed || currentSampleY != sampleY || currentDimensionID != dimensionID {
            commonBase.render(status: "Preparing generator state…")
            currentSeed = seed
            currentSampleY = sampleY
            currentDimensionID = dimensionID
            awaitingFirstTileForSeed = true
            mapView.currentSeed = seed
            mapView.removeAllTiles()
            mapView.tileImages.removeAll(keepingCapacity: true)
            mapView.lootContainers.removeAll()
        }
        scheduleRender(immediately: true)
    }

    @objc private func randomSeed() {
        seedInput?.stringValue = String(Int64.random(in: Int64.min...Int64.max))
        renderSeed()
    }

    @objc private func useMapCenterForLootSearch() {
        lootSearchXInput?.stringValue = "\(Int32(clamping: Int(mapView.centerX.rounded())))"
        lootSearchZInput?.stringValue = "\(Int32(clamping: Int(mapView.centerZ.rounded())))"
    }

    @objc private func cancelLootSearch() {
        guard lootSearchTask != nil else { return }
        lootSearchTask?.cancel()
        lootSearchTask = nil
        lootSearchRequest += 1
        lootSearchCurrentLabel?.stringValue = "Cancelled."
        renderLootSearchGroups("Cancelled. \(lootSearchResults.count) matching chest\(lootSearchResults.count == 1 ? "" : "s") kept.")
    }

    @objc private func advancedThreadCountChanged(_ sender: NSStepper) {
        let count = sender.integerValue
        if sender.identifier?.rawValue == "loot-search-threads" {
            guard count != lootSearchThreadCount else { return }
            lootSearchThreadCount = count
        } else {
            threadField?.stringValue = "\(count)"
            guard count != threadCount else { return }
            threadCount = count
        }
        loadDatapack(threadCount: threadCount)
    }

    @objc private func llvmCompilationChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard enabled != enableDensityCompilation else { return }
        enableDensityCompilation = enabled
        loadDatapack(threadCount: threadCount)
    }

    @objc private func tileGenerationModeChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let mode = MapTileGenerationMode.allCases.first(where: { $0.title == title }),
              mode != tileGenerationMode
        else { return }
        tileGenerationMode = mode
        // Cached complete tiles would hide the scheduling experiment.
        mapView.removeAllTiles()
        deferredStructureResults.removeAll(keepingCapacity: true)
        if currentSeed != nil { renderVisibleRegion() }
    }

    @objc private func minecraftVersionChanged() {
        guard let version = minecraftVersionInput?.titleOfSelectedItem,
              let datapack = vanillaDatapacks.first(where: { $0.version == version }),
              datapack != selectedDatapack
        else { return }
        selectedDatapack = datapack
        loadDatapack(threadCount: threadCount)
    }

    private func loadDatapack(threadCount: Int) {
        let datapack = selectedDatapack
        let searchThreadCount = lootSearchThreadCount
        let useLLVM = enableDensityCompilation
        generation += 1
        renderTask?.cancel()
        renderTimer?.invalidate()
        renderTimer = nil
        scheduler = nil
            mapView.removeAllTiles()
        mapView.tileImages.removeAll(keepingCapacity: true)
        mapView.lootContainers.removeAll(keepingCapacity: true)
        completedTiles = 0
        pendingTiles = 0
        awaitingFirstTileForSeed = currentSeed != nil
        commonBase.render(status: "Loading Minecraft \(datapack.version) datapack for \(threadCount) generation thread\(threadCount == 1 ? "" : "s")…")
        biomeGenerationStatusLabel?.stringValue = "Biomes: preparing generator."
        structureGenerationStatusLabel?.stringValue = "Structures: waiting for generator."
        do {
            dataPackRoot = try Self.findDatapackRoot(for: datapack)
        } catch {
            commonBase.render(status: "Could not locate the Minecraft datapack: \(error)", isError: true)
            return
        }
        guard let root = dataPackRoot else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard self.threadCount == threadCount, self.lootSearchThreadCount == searchThreadCount,
                      self.enableDensityCompilation == useLLVM, self.selectedDatapack == datapack else { return }
                self.commonBase.render(status: "Preparing world generator…")
                let next = NativeGenerationPlatform(
                    threadCount: threadCount,
                    lootSearchThreadCount: searchThreadCount,
                    enableDensityCompilation: useLLVM
                )
                try await next.initialize(rootURL: root, packFormat: datapack.packFormat)
                let registry = await next.registryIDs()
                guard self.threadCount == threadCount, self.lootSearchThreadCount == searchThreadCount,
                      self.enableDensityCompilation == useLLVM, self.selectedDatapack == datapack else { return }
                self.scheduler = next
                self.populateBiomeList(registry.biomes)
                self.populateDimensionPicker(registry.dimensions)
                self.populateStructureList(registry.structures)
                self.commonBase.render(status: "Minecraft \(datapack.version) datapack ready. Enter a seed and click Render.")
                self.biomeGenerationStatusLabel?.stringValue = "Biomes: ready to render."
                self.structureGenerationStatusLabel?.stringValue = "Structures: ready to render."
                if self.currentSeed != nil { self.renderVisibleRegion() }
            } catch {
                guard self.threadCount == threadCount, self.selectedDatapack == datapack else { return }
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
        let centerTileX = Int(floor(mapView.centerX / span))
        let centerTileZ = Int(floor(mapView.centerZ / span))
        for (tileX, tileZ) in MapMath.centerFirstTileCoordinates(
            minTileX: minTileX,
            maxTileX: maxTileX,
            minTileZ: minTileZ,
            maxTileZ: maxTileZ,
            centerTileX: centerTileX,
            centerTileZ: centerTileZ
        ) {
                let key = NativeTileKey(seed: seed, scaleKey: scaleKey, tileX: tileX, tileZ: tileZ)
                if let cached = mapView.tiles[key],
                   enabledStructureSets.isEmpty || cached.structuresComplete {
                    continue
                }
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
                    dimensionID: currentDimensionID,
                    enabledStructureSets: enabledStructureSets
                ))
        }
        pendingTiles = requests.count
        completedTiles = 0
        pendingStructureTiles = enabledStructureSets.isEmpty ? 0 : requests.count
        completedStructureTiles = 0
        deferredStructureResults.removeAll(keepingCapacity: true)
        biomeGenerationStatusLabel?.stringValue = requests.isEmpty
            ? "Biomes: ready from tile cache."
            : "Biomes: 0/\(requests.count) tile(s) ready."
        structureGenerationStatusLabel?.stringValue = requests.isEmpty
            ? "Structures: ready from tile cache."
            : (enabledStructureSets.isEmpty
                ? "Structures: disabled."
                : "Structures: 0/\(requests.count) tile(s) ready.")
        mapView.needsDisplay = true
        if requests.isEmpty {
            commonBase.render(status: "Rendered seed \(seed) from the native tile cache.")
            return
        }
        commonBase.render(status: awaitingFirstTileForSeed
            ? "Generating centre biome tiles…"
            : "Rendering seed \(seed) on \(threadCount) thread\(threadCount == 1 ? "" : "s"). Loading \(requests.count) tile(s)…")
        updateDebug(lastTile: nil)
        if tileGenerationMode != .combined {
            scheduleSplitTileGeneration(
                requests: requests,
                scheduler: scheduler,
                generation: activeGeneration
            )
            return
        }
        let concurrency = threadCount
        renderTask = Task { [weak self] in
            await withTaskGroup(of: Result<MapTilePresentation, Error>.self) { group in
                var nextRequest = 0
                for _ in 0..<min(concurrency, requests.count) {
                    let request = requests[nextRequest]
                    nextRequest += 1
                    group.addTask {
                        do {
                            return .success(try await scheduler.generateTile(request) { [weak self] in
                                Task { @MainActor [weak self] in
                                    self?.structureGenerationStatusLabel?.stringValue = "Generating strongholds…"
                                }
                            })
                        }
                        catch { return .failure(error) }
                    }
                }
                for await result in group {
                    if nextRequest < requests.count {
                        let request = requests[nextRequest]
                        nextRequest += 1
                        group.addTask {
                        do {
                            return .success(try await scheduler.generateTile(request) { [weak self] in
                                Task { @MainActor [weak self] in
                                    self?.structureGenerationStatusLabel?.stringValue = "Generating strongholds…"
                                }
                            })
                        }
                            catch { return .failure(error) }
                        }
                    }
                    guard let self, activeGeneration == self.generation else { continue }
                    switch result {
                    case .success(let tile):
                        self.commonBase.render(tile: tile)
                    case .failure(let error):
                        self.pendingTiles = max(0, self.pendingTiles - 1)
                        self.commonBase.render(status: "Render failed: \(error)", isError: true)
                        self.biomeGenerationStatusLabel?.stringValue = "Biomes: generation failed."
                        self.structureGenerationStatusLabel?.stringValue = "Structures: generation failed."
                    }
                }
            }
        }
    }

    private func scheduleSplitTileGeneration(
        requests: [MapTileRequest],
        scheduler: NativeGenerationPlatform,
        generation activeGeneration: Int
    ) {
        let mode = tileGenerationMode
        renderTask = Task { [weak self] in
            await withTaskGroup(of: NativeTileGenerationResult.self) { group in
                for request in requests {
                    group.addTask {
                        do { return .biome(.success(try await scheduler.generateBiomeTile(request))) }
                        catch { return .biome(.failure(error)) }
                    }
                    if mode == .parallelStructures, !(request.enabledStructureSets ?? []).isEmpty {
                        group.addTask {
                            do {
                                return .structures(.success(try await scheduler.generateStructures(for: request) { [weak self] in
                                    Task { @MainActor [weak self] in
                                        self?.structureGenerationStatusLabel?.stringValue = "Generating strongholds…"
                                    }
                                }))
                            }
                            catch { return .structures(.failure(error)) }
                        }
                    }
                }
                for await result in group {
                    guard let self, activeGeneration == self.generation else { continue }
                    switch result {
                    case .biome(.success(let tile)):
                        self.installSplitBiomeTile(tile)
                        if mode == .deferredStructures,
                           !self.enabledStructureSets.isEmpty,
                           let request = requests.first(where: { $0.tileX == tile.tileX && $0.tileZ == tile.tileZ }) {
                            group.addTask {
                                do {
                                    return .structures(.success(try await scheduler.generateStructures(for: request) { [weak self] in
                                        Task { @MainActor [weak self] in
                                            self?.structureGenerationStatusLabel?.stringValue = "Generating strongholds…"
                                        }
                                    }))
                                }
                                catch { return .structures(.failure(error)) }
                            }
                        }
                    case .structures(.success(let structures)):
                        self.installSplitStructures(structures)
                    case .biome(.failure(let error)), .structures(.failure(let error)):
                        self.commonBase.render(status: "Render failed: \(error)", isError: true)
                    }
                }
            }
        }
    }

    private func installSplitBiomeTile(_ tile: MapTilePresentation) {
        guard tile.generation == generation, tile.seed == currentSeed else { return }
        mapView.install(tile: tile)
        completedTiles += 1
        pendingTiles = max(0, pendingTiles - 1)
        awaitingFirstTileForSeed = false
        biomeGenerationStatusLabel?.stringValue = "Biomes: \(completedTiles)/\(completedTiles + pendingTiles) tile(s) ready."
        updateDebug(lastTile: tile)
        let key = NativeTileKey(seed: tile.seed, scaleKey: tile.scaleKey, tileX: tile.tileX, tileZ: tile.tileZ)
        if let structures = deferredStructureResults.removeValue(forKey: key) {
            installSplitStructures(structures)
        }
    }

    private func installSplitStructures(_ structures: MapTileStructuresPresentation) {
        guard structures.generation == generation, structures.seed == currentSeed else { return }
        let key = NativeTileKey(seed: structures.seed, scaleKey: structures.scaleKey, tileX: structures.tileX, tileZ: structures.tileZ)
        guard let tile = mapView.tiles[key], tile.generation == structures.generation else {
            deferredStructureResults[key] = structures
            return
        }
        mapView.install(tile: MapTilePresentation(
            generation: tile.generation, seed: tile.seed, scaleKey: tile.scaleKey, tileX: tile.tileX, tileZ: tile.tileZ,
            width: tile.width, height: tile.height, palette: tile.palette, biomeIndices: tile.biomeIndices,
            structures: structures.structures, structuresComplete: true, generationMilliseconds: tile.generationMilliseconds,
            densityCompilationMilliseconds: tile.densityCompilationMilliseconds,
            densityCompilationBackend: tile.densityCompilationBackend
        ))
        completedStructureTiles += 1
        pendingStructureTiles = max(0, pendingStructureTiles - 1)
        structureGenerationStatusLabel?.stringValue = pendingStructureTiles == 0
            ? "Structures: ready."
            : "Structures: \(completedStructureTiles)/\(completedStructureTiles + pendingStructureTiles) tile(s) ready."
    }

    private func updateDebug(lastTile: MapTilePresentation?) {
        var lines = [
            "Threads: \(threadCount)",
            "Tile scheduling: \(tileGenerationMode.title)",
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

    private static func findDatapackRoot(for datapack: VanillaDatapack) throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DAPPERMAP_DATAPACK"] {
            candidates.append(URL(fileURLWithPath: override.replacingOccurrences(of: "{version}", with: datapack.version), isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(datapack.nativeDataDirectory, isDirectory: true))
            candidates.append(resources.appendingPathComponent(datapack.version, isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(datapack.nativeDataDirectory, isDirectory: true)
        )
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(datapack.nativeDataDirectory, isDirectory: true)
        )
        for candidate in candidates {
            let biomeDirectory = candidate.appendingPathComponent("data/minecraft/worldgen/biome", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: biomeDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        throw NativeAppError.message(
            "Extract Minecraft \(datapack.version) to \(datapack.nativeDataDirectory), set DAPPERMAP_DATAPACK, or run from the repository root. DAPPERMAP_DATAPACK may contain {version}."
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
        let controller = NativeAppController()
        self.controller = controller
        installApplicationMenu()
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
        let aboutItem = appMenu.addItem(withTitle: "About DapperMap", action: #selector(NativeAppController.showAboutPopup), keyEquivalent: "")
        aboutItem.target = controller
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DapperMap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
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
