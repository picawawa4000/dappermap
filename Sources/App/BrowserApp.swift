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
#if os(WASI)
@MainActor
final class BrowserApp: DapperMapPlatform {
    private let document: JSObject
    private let viewport: JSObject
    private let seedInput: JSObject
    private let dimensionInput: JSObject
    private let yInput: JSObject
    private let renderButton: JSObject
    private let statusElement: JSObject
    private let biomeGenerationStatusElement: JSObject
    private let structureGenerationStatusElement: JSObject
    private let biomeResetButton: JSObject
    private let biomeImportButton: JSObject
    private let biomeExportButton: JSObject
    private let biomeExportCubiomesButton: JSObject
    private let biomeImportInput: JSObject
    private let biomeSummaryElement: JSObject
    private let biomeEmptyElement: JSObject
    private let biomeListElement: JSObject
    private let structureResetButton: JSObject
    private let structureSummaryElement: JSObject
    private let structureEmptyElement: JSObject
    private let structureListElement: JSObject
    private let lootInfoElement: JSObject
    private let lootFilterInput: JSObject
    private let lootMessageElement: JSObject
    private let lootListElement: JSObject
    private let debugLastTileElement: JSObject
    private let debugGenerationTimeElement: JSObject
    private let debugDensityCompilationElement: JSObject
    private let debugRenderTimeElement: JSObject
    private let debugPendingTilesElement: JSObject
    private let debugCachedTilesElement: JSObject
    private let debugStructureTimeElement: JSObject
    private let debugStructureSamplingElement: JSObject
    private let debugStructureValidationElement: JSObject
    private let debugStructureCandidatesElement: JSObject
    private let debugStructureAcceptedElement: JSObject
    private let debugStructureRejectedElement: JSObject
    private let debugStructureCacheHitsElement: JSObject
    private let debugStructureTypesElement: JSObject
    private let tooltipElement: JSObject
    private let canvas: JSObject
    private let context: JSObject
    private let overlayCanvas: JSObject
    private let overlayContext: JSObject
    private let snapshotCanvas: JSObject
    private let snapshotContext: JSObject
    private let fallbackCanvas: JSObject
    private let fallbackContext: JSObject

    private var retainedClosures: [JSClosure] = []
    private var pendingTimer: JSTimer?
    private var generatorReady = false
    private var currentSeed: WorldSeed?
    private var currentSampleY: Int32 = defaultSampleY
    private var currentDimensionID = "minecraft:overworld"
    private var awaitingFirstTileForSeed = false
    private let tileGenerator: TileGenerationService
    private var inFlightStructureTask: Task<Void, Never>?
    private var inFlightConcentricStructureTask: Task<Void, Never>?
    private var requestedStructureGeneration: Int?
    private var inFlightTileJob: PendingTileJob?
    private var inFlightTileTask: Task<Void, Never>?
    private var inFlightTileStructureJob: PendingTileStructureJob?
    private var inFlightTileStructureTask: Task<Void, Never>?
    private var pendingRenderTimer: JSTimer?
    private var pendingTileTimer: JSTimer?
    private var latestViewState: ViewState?
    private var tileCache: [TileCacheKey: CachedTile] = [:]
    private var tileAtlas: TileAtlas?
    private var fallbackTileAtlas: TileAtlas?
    private var pendingTileJobs: [PendingTileJob] = []
    private var pendingTileStructureJobs: [PendingTileStructureJob] = []
    private var biomeTilesTotal = 0
    private var biomeTilesCompleted = 0
    private var activeViewGeneration = 0
    private var profilingEnabled = false
    private var profilingMetrics = TileProfilingMetrics()
    private var tileDebugMetrics = TileDebugMetrics()
    private var structureDebugMetrics = StructureProfilingMetrics()
    private var biomeColors: [String: BiomeColor] = [:]
    private var biomeColorCache: [String: String] = [:]
    private var biomeRowElements: [String: BiomeRowElements] = [:]
    private var loadedBiomeIDs: [String] = []
    private var structureColors: [String: BiomeColor] = [:]
    private var enabledStructureSets: [String: Bool] = [:]
    private var structureSetSpacings: [String: Int32] = [:]
    private var structureSetFrequencies: Set<String> = []
    private var structureSetStructureIDs: [String: [String]] = [:]
    private var structureRowElements: [String: StructureRowElements] = [:]
    private var loadedStructureIDs: [String] = []
    private var visibleStructurePoints: [StructurePoint] = []
    private var visibleLootContainers: [LootContainerPoint] = []
    private var lootFilter = ""
    private var activeLootStructure: StructurePoint?
    private var activeLootRequest = 0
    private var lootContainerDetails: [LootContainerPoint: JSObject] = [:]
    private var inFlightLootTask: Task<Void, Never>?
    private var viewCenterX = 0.0
    private var viewCenterZ = 0.0
    private var viewBlocksPerPixel = 1.0
    private var viewportWidth = mapSize
    private var viewportHeight = mapSize
    private var dragPointerID: Double?
    private var dragStartClientX = 0.0
    private var dragStartClientY = 0.0
    private var dragOriginCenterX = 0.0
    private var dragOriginCenterZ = 0.0
    private var dragDidMove = false
    private lazy var commonBase = DapperMapBase(platform: self)

    private let overworldDimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    private let overworldNoiseSettings = RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
    private let tileSize = 256
    private let placeholderColor = "#ece6d3"
    private let gridLineColor = "rgba(29, 41, 29, 0.18)"
    private let gridLabelColor = "rgba(29, 41, 29, 0.72)"

    init(tileGenerator: TileGenerationService) {
        self.tileGenerator = tileGenerator
        self.document = JSObject.global.document.object!
        self.viewport = document.getElementById!("map-viewport").object!
        self.seedInput = document.getElementById!("seed-input").object!
        self.dimensionInput = document.getElementById!("dimension-input").object!
        self.yInput = document.getElementById!("y-input").object!
        self.renderButton = document.getElementById!("render-button").object!
        self.statusElement = document.getElementById!("status").object!
        self.biomeGenerationStatusElement = document.getElementById!("biome-generation-status").object!
        self.structureGenerationStatusElement = document.getElementById!("structure-generation-status").object!
        self.biomeResetButton = document.getElementById!("biome-reset-button").object!
        self.biomeImportButton = document.getElementById!("biome-import-button").object!
        self.biomeExportButton = document.getElementById!("biome-export-button").object!
        self.biomeExportCubiomesButton = document.getElementById!("biome-export-cubiomes-button").object!
        self.biomeImportInput = document.getElementById!("biome-import-input").object!
        self.biomeSummaryElement = document.getElementById!("biome-summary").object!
        self.biomeEmptyElement = document.getElementById!("biome-empty").object!
        self.biomeListElement = document.getElementById!("biome-list").object!
        self.structureResetButton = document.getElementById!("structure-reset-button").object!
        self.structureSummaryElement = document.getElementById!("structure-summary").object!
        self.structureEmptyElement = document.getElementById!("structure-empty").object!
        self.structureListElement = document.getElementById!("structure-list").object!
        self.lootInfoElement = document.getElementById!("loot-info").object!
        self.lootFilterInput = document.getElementById!("loot-filter-input").object!
        self.lootMessageElement = document.getElementById!("loot-message").object!
        self.lootListElement = document.getElementById!("loot-list").object!
        self.debugLastTileElement = document.getElementById!("debug-last-tile").object!
        self.debugGenerationTimeElement = document.getElementById!("debug-generation-time").object!
        self.debugDensityCompilationElement = document.getElementById!("debug-density-compilation").object!
        self.debugRenderTimeElement = document.getElementById!("debug-render-time").object!
        self.debugPendingTilesElement = document.getElementById!("debug-pending-tiles").object!
        self.debugCachedTilesElement = document.getElementById!("debug-cached-tiles").object!
        self.debugStructureTimeElement = document.getElementById!("debug-structure-time").object!
        self.debugStructureSamplingElement = document.getElementById!("debug-structure-sampling").object!
        self.debugStructureValidationElement = document.getElementById!("debug-structure-validation").object!
        self.debugStructureCandidatesElement = document.getElementById!("debug-structure-candidates").object!
        self.debugStructureAcceptedElement = document.getElementById!("debug-structure-accepted").object!
        self.debugStructureRejectedElement = document.getElementById!("debug-structure-rejected").object!
        self.debugStructureCacheHitsElement = document.getElementById!("debug-structure-cache-hits").object!
        self.debugStructureTypesElement = document.getElementById!("debug-structure-types").object!
        self.tooltipElement = document.getElementById!("map-tooltip").object!
        self.canvas = document.getElementById!("map-canvas").object!
        self.context = canvas.getContext!("2d").object!
        self.overlayCanvas = document.getElementById!("map-overlay").object!
        self.overlayContext = overlayCanvas.getContext!("2d").object!
        self.snapshotCanvas = document.createElement!("canvas").object!
        self.snapshotContext = snapshotCanvas.getContext!("2d").object!
        self.fallbackCanvas = document.createElement!("canvas").object!
        self.fallbackContext = fallbackCanvas.getContext!("2d").object!
    }

    func start() {
        profilingEnabled = false
        if profilingEnabled {
            viewCenterX = JSObject.global["__dappermapProfileCenterX"].number ?? viewCenterX
            viewCenterZ = JSObject.global["__dappermapProfileCenterZ"].number ?? viewCenterZ
            viewBlocksPerPixel = JSObject.global["__dappermapProfileBlocksPerPixel"].number ?? viewBlocksPerPixel
        }
        commonBase.renderSidebar()
        updateDebugPanel()
        canvas.width = mapSize.jsValue
        canvas.height = mapSize.jsValue
        overlayCanvas.width = mapSize.jsValue
        overlayCanvas.height = mapSize.jsValue
        snapshotCanvas.width = mapSize.jsValue
        snapshotCanvas.height = mapSize.jsValue
        fallbackCanvas.width = mapSize.jsValue
        fallbackCanvas.height = mapSize.jsValue
        configureCanvasContext(context)
        configureCanvasContext(overlayContext)
        configureCanvasContext(snapshotContext)
        configureCanvasContext(fallbackContext)
        syncViewportSize()
        attachHandlers()
        renderLootPanel(message: nil)
        setLoading(true)
        setStatus("Loading Minecraft 1.21.11 datapack…")
        scheduleNextTick { [weak self] in
            self?.loadDefaultDatapack()
        }
    }

    private func handleGeneratedTile(_ result: GeneratedTile, for job: PendingTileJob) {
        inFlightTileJob = nil
        inFlightTileTask = nil
        guard
            job.generation == activeViewGeneration,
            let seed = currentSeed,
            seed == job.seed,
            currentDimensionID == job.dimensionID
        else {
            scheduleNextTileBatch()
            return
        }

        let key = TileCacheKey(seed: seed, scaleKey: scaleKey(for: job.tileBlocksPerPixel), tileX: job.tileX, tileZ: job.tileZ)
        tileCache[key] = result.tile
        if let biomeCache = result.biomeCache,
           !(job.enabledStructureSets?.isEmpty ?? false) {
            pendingTileStructureJobs.append(PendingTileStructureJob(tileJob: job, biomeCache: biomeCache))
        }
        biomeTilesCompleted += 1
        setBiomeGenerationStatus("Biomes: \(biomeTilesCompleted)/\(biomeTilesTotal) tile(s) ready.")
        refreshVisibleStructures(for: currentViewState())
        tileDebugMetrics.tileX = job.tileX
        tileDebugMetrics.tileZ = job.tileZ
        tileDebugMetrics.blocksPerPixel = job.tileBlocksPerPixel
        tileDebugMetrics.generationMilliseconds = result.generationMilliseconds
        tileDebugMetrics.densityCompilationMilliseconds = result.densityCompilationMilliseconds
        tileDebugMetrics.densityCompilationBackend = result.densityCompilationBackend
        awaitingFirstTileForSeed = false

        let renderStart = Date()
        commonBase.render(tile: MapTilePresentation(
            generation: job.generation,
            seed: Int64(bitPattern: job.seed),
            scaleKey: scaleKey(for: job.tileBlocksPerPixel),
            tileX: job.tileX,
            tileZ: job.tileZ,
            width: result.tile.width,
            height: result.tile.height,
            palette: result.tile.palette,
            biomeIndices: result.tile.biomeIndices,
            structures: result.tile.structurePoints.map {
                MapStructurePresentation(setID: $0.setID, structureID: $0.structureID, x: $0.x, z: $0.z)
            },
            generationMilliseconds: result.generationMilliseconds,
            densityCompilationMilliseconds: result.densityCompilationMilliseconds,
            densityCompilationBackend: result.densityCompilationBackend
        ))
        tileDebugMetrics.renderMilliseconds = Date().timeIntervalSince(renderStart) * 1_000.0
        updateDebugPanel()

        guard let viewState = latestViewState else { return }
        if pendingTileJobs.isEmpty {
            setStatus("Rendered seed \(displaySeed(seed)) at Y=\(currentSampleY), centered on (\(Int(viewState.centerX.rounded())), \(Int(viewState.centerZ.rounded()))) with \(String(format: "%.2f", viewState.blocksPerPixel)) block(s) per pixel.")
            scheduleNextTileStructure()
        } else {
            scheduleNextTileBatch()
        }
    }

    private func handleTileGenerationFailure(_ error: Error, for job: PendingTileJob) {
        inFlightTileJob = nil
        inFlightTileTask = nil
        if job.generation != activeViewGeneration || job.seed != currentSeed {
            scheduleNextTileBatch()
            return
        }
        pendingTileJobs.removeAll(keepingCapacity: true)
        updateDebugPanel()
        setStatus("Render failed: \(error)", isError: true)
        setBiomeGenerationStatus("Biomes: failed — \(error)", isError: true)
        setStructureGenerationStatus("Structures: stopped because biome generation failed.", isError: true)
    }

    private func attachHandlers() {
        let clickClosure = JSClosure { [weak self] _ in
            self?.prepareRender()
            return .undefined
        }
        retainedClosures.append(clickClosure)
        _ = renderButton.addEventListener!("click", clickClosure)

        let keyClosure = JSClosure { [weak self] args in
            guard let event = args.first?.object else { return .undefined }
            guard event.key.string == "Enter" else { return .undefined }
            _ = event.preventDefault!()
            self?.prepareRender()
            return .undefined
        }
        retainedClosures.append(keyClosure)
        _ = seedInput.addEventListener!("keydown", keyClosure)
        _ = yInput.addEventListener!("keydown", keyClosure)

        let dimensionChangeClosure = JSClosure { [weak self] _ in
            self?.prepareRender()
            return .undefined
        }
        retainedClosures.append(dimensionChangeClosure)
        _ = dimensionInput.addEventListener!("change", dimensionChangeClosure)

        let biomeResetClosure = JSClosure { [weak self] _ in
            self?.resetBiomeColorsToDefaults()
            return .undefined
        }
        retainedClosures.append(biomeResetClosure)
        _ = biomeResetButton.addEventListener!("click", biomeResetClosure)

        let structureResetClosure = JSClosure { [weak self] _ in
            self?.resetStructureColorsToDefaults()
            return .undefined
        }
        retainedClosures.append(structureResetClosure)
        _ = structureResetButton.addEventListener!("click", structureResetClosure)

        let lootFilterClosure = JSClosure { [weak self] _ in
            guard let self else { return .undefined }
            self.lootFilter = self.lootFilterInput.value.string ?? ""
            self.renderLootPanel(message: nil)
            return .undefined
        }
        retainedClosures.append(lootFilterClosure)
        _ = lootFilterInput.addEventListener!("input", lootFilterClosure)

        let biomeImportButtonClosure = JSClosure { [weak self] _ in
            self?.biomeImportInput.value = "".jsValue
            _ = self?.biomeImportInput.click?()
            return .undefined
        }
        retainedClosures.append(biomeImportButtonClosure)
        _ = biomeImportButton.addEventListener!("click", biomeImportButtonClosure)

        let biomeImportChangeClosure = JSClosure { [weak self] _ in
            self?.handleBiomeImportSelection()
            return .undefined
        }
        retainedClosures.append(biomeImportChangeClosure)
        _ = biomeImportInput.addEventListener!("change", biomeImportChangeClosure)

        let biomeExportClosure = JSClosure { [weak self] _ in
            self?.exportBiomeColors(usingCubiomesFormat: false)
            return .undefined
        }
        retainedClosures.append(biomeExportClosure)
        _ = biomeExportButton.addEventListener!("click", biomeExportClosure)

        let biomeExportCubiomesClosure = JSClosure { [weak self] _ in
            self?.exportBiomeColors(usingCubiomesFormat: true)
            return .undefined
        }
        retainedClosures.append(biomeExportCubiomesClosure)
        _ = biomeExportCubiomesButton.addEventListener!("click", biomeExportCubiomesClosure)

        let wheelClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            _ = event.preventDefault!()
            self.syncViewportSize()
            let factor = exp((event.deltaY.number ?? 0.0) * 0.0015)
            self.zoom(
                atClientX: event.clientX.number ?? 0.0,
                clientY: event.clientY.number ?? 0.0,
                factor: factor
            )
            return .undefined
        }
        retainedClosures.append(wheelClosure)
        _ = viewport.addEventListener!("wheel", wheelClosure)

        let pointerDownClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            _ = event.preventDefault!()
            self.syncViewportSize()
            self.dragPointerID = event.pointerId.number
            self.dragStartClientX = event.clientX.number ?? 0.0
            self.dragStartClientY = event.clientY.number ?? 0.0
            self.dragOriginCenterX = self.viewCenterX
            self.dragOriginCenterZ = self.viewCenterZ
            self.dragDidMove = false
            self.setDragging(true)
            _ = self.viewport.setPointerCapture?(event.pointerId)
            return .undefined
        }
        retainedClosures.append(pointerDownClosure)
        _ = viewport.addEventListener!("pointerdown", pointerDownClosure)

        let pointerMoveClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            self.updateTooltip(forClientX: event.clientX.number ?? 0.0, clientY: event.clientY.number ?? 0.0)
            guard self.dragPointerID == event.pointerId.number else { return .undefined }

            let dx = (event.clientX.number ?? 0.0) - self.dragStartClientX
            let dy = (event.clientY.number ?? 0.0) - self.dragStartClientY
            if abs(dx) > 3.0 || abs(dy) > 3.0 { self.dragDidMove = true }
            self.viewCenterX = self.dragOriginCenterX - dx * self.viewBlocksPerPixel
            self.viewCenterZ = self.dragOriginCenterZ - dy * self.viewBlocksPerPixel
            self.previewCurrentViewIfPossible()
            self.scheduleVisibleRegionRender()
            return .undefined
        }
        retainedClosures.append(pointerMoveClosure)
        _ = viewport.addEventListener!("pointermove", pointerMoveClosure)

        let pointerEndClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            guard self.dragPointerID == event.pointerId.number else { return .undefined }

            self.dragPointerID = nil
            self.setDragging(false)
            _ = self.viewport.releasePointerCapture?(event.pointerId)
            self.scheduleVisibleRegionRender()
            return .undefined
        }
        retainedClosures.append(pointerEndClosure)
        _ = viewport.addEventListener!("pointerup", pointerEndClosure)
        _ = viewport.addEventListener!("pointercancel", pointerEndClosure)

        // Use the browser's completed click gesture for selection. `pointerup` is also used for
        // drag cleanup and can be suppressed by pointer capture on some browsers.
        let mapClickClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            self.selectMapItem(atClientX: event.clientX.number ?? 0.0, clientY: event.clientY.number ?? 0.0)
            return .undefined
        }
        retainedClosures.append(mapClickClosure)
        _ = viewport.addEventListener!("click", mapClickClosure)

        let pointerLeaveClosure = JSClosure { [weak self] _ in
            self?.hideTooltip()
            return .undefined
        }
        retainedClosures.append(pointerLeaveClosure)
        _ = viewport.addEventListener!("pointerleave", pointerLeaveClosure)

        let doubleClickClosure = JSClosure { [weak self] args in
            guard let self, let event = args.first?.object else { return .undefined }
            _ = event.preventDefault!()
            self.syncViewportSize()
            self.zoom(
                atClientX: event.clientX.number ?? 0.0,
                clientY: event.clientY.number ?? 0.0,
                factor: 0.5
            )
            return .undefined
        }
        retainedClosures.append(doubleClickClosure)
        _ = viewport.addEventListener!("dblclick", doubleClickClosure)

        let resizeClosure = JSClosure { [weak self] _ in
            guard let self else { return .undefined }
            let resized = self.syncViewportSize()
            if resized {
                self.previewCurrentViewIfPossible()
                self.scheduleVisibleRegionRender()
            }
            return .undefined
        }
        retainedClosures.append(resizeClosure)
        if let windowObject = JSObject.global.window.object {
            _ = windowObject.addEventListener!("resize", resizeClosure)
        }
    }

    private func loadDefaultDatapack() {
        fetchText(at: defaultBundlePath) { [weak self] (result: Result<String, BrowserAppError>) in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.setLoading(false)
                self.setStatus("Failed to load datapack bundle: \(self.describe(error))", isError: true)
            case .success(let text):
                // The tile worker owns the materialised DataPack. Retaining one here as well
                // duplicates its large registries in shared WebAssembly memory and can force a
                // WebKit-hostile memory growth before the first render.
                self.startTileGenerator(bundleText: text)
            }
        }
    }

    private func startTileGenerator(bundleText: String) {
        setStatus("Compiling density functions…")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.tileGenerator.initialize(bundleText: bundleText)
                let metadata = await self.tileGenerator.browserRegistryMetadata()
                self.reloadDimensionPicker(using: metadata.dimensionIDs)
                self.reloadBiomeEditor(using: metadata.biomeIDs)
                self.reloadStructureEditor(using: metadata.structureSets)
                self.generatorReady = true
                self.setLoading(false)
                self.setStatus("Datapack ready. Enter a seed and click Render.")
            } catch {
                self.setLoading(false)
                self.setStatus("Failed to start tile generation worker: \(error)", isError: true)
            }
        }
    }

    private func prepareRender() {
        guard generatorReady else {
            setStatus("Datapack is still loading.", isError: true)
            return
        }
        guard let seed = parseSeed(seedInput.value.string ?? "") else {
            setStatus("Enter a valid 64-bit Minecraft seed.", isError: true)
            return
        }

        let sampleY = selectedSampleY()
        let dimensionID = dimensionInput.value.string ?? "minecraft:overworld"
        if currentSeed != seed || currentSampleY != sampleY || currentDimensionID != dimensionID {
            setStatus("Compiling density functions…")
            currentSeed = seed
            currentSampleY = sampleY
            currentDimensionID = dimensionID
            awaitingFirstTileForSeed = true
            tileCache.removeAll(keepingCapacity: true)
            pendingTileStructureJobs.removeAll(keepingCapacity: true)
            inFlightTileStructureTask?.cancel()
            tileAtlas = nil
            fallbackTileAtlas = nil
            releaseAtlasCanvases()
            visibleStructurePoints.removeAll(keepingCapacity: true)
            visibleLootContainers.removeAll(keepingCapacity: true)
            activeLootStructure = nil
            activeLootRequest += 1
            renderLootPanel(message: nil)
            tileDebugMetrics = TileDebugMetrics()
            structureDebugMetrics = StructureProfilingMetrics()
            updateDebugPanel()
            context.fillStyle = placeholderColor.jsValue
            _ = context.fillRect!(0, 0, viewportWidth, viewportHeight)
        }

        scheduleVisibleRegionRender()
    }

    private func scheduleVisibleRegionRender() {
        guard currentSeed != nil else { return }
        syncViewportSize()
        let viewState = currentViewState()

        latestViewState = viewState
        activeViewGeneration += 1
        // The worker is serial. Ask obsolete work to stop at its next sampling boundary so a
        // zoom or pan does not sit behind structure validation for the previous viewport.
        inFlightTileTask?.cancel()
        inFlightTileStructureTask?.cancel()
        pendingTileTimer = nil
        pendingTileJobs.removeAll(keepingCapacity: true)
        guard pendingRenderTimer == nil else { return }

        pendingRenderTimer = JSTimer(millisecondsDelay: 0) { [weak self] in
            guard let self else { return }
            self.pendingRenderTimer = nil
            self.renderVisibleRegion(generation: self.activeViewGeneration)
        }
    }

    private func renderVisibleRegion(generation: Int) {
        guard let seed = currentSeed, let viewState = latestViewState else {
            return
        }
        guard generation == activeViewGeneration else { return }
        if profilingEnabled, profilingMetrics.generation != generation {
            profilingMetrics = TileProfilingMetrics(generation: generation)
        }

        canvas.width = viewState.viewportWidth.jsValue
        canvas.height = viewState.viewportHeight.jsValue
        overlayCanvas.width = viewState.viewportWidth.jsValue
        overlayCanvas.height = viewState.viewportHeight.jsValue
        configureCanvasContext(context)
        configureCanvasContext(overlayContext)

        drawVisibleRegion(seed: seed, viewState: viewState, generation: generation)
        drawGridOverlay(for: viewState)
        pruneTileCache(for: seed, around: viewState)

        if pendingTileJobs.isEmpty {
            fallbackTileAtlas = nil
            releaseCanvas(fallbackCanvas)
            drawTileAtlas(for: viewState, on: context)
            drawGridOverlay(for: viewState)
            emitProfilingMetrics()
            setStatus(
                "Rendered seed \(displaySeed(seed)) at Y=\(currentSampleY), centered on (\(Int(viewState.centerX.rounded())), \(Int(viewState.centerZ.rounded()))) with \(String(format: "%.2f", viewState.blocksPerPixel)) block(s) per pixel."
            )
        } else if awaitingFirstTileForSeed {
            setStatus("Compiling density functions…")
            scheduleNextTileBatch()
        } else {
            setStatus(
                "Rendering seed \(displaySeed(seed)) at Y=\(currentSampleY), centered on (\(Int(viewState.centerX.rounded())), \(Int(viewState.centerZ.rounded()))). Loading \(pendingTileJobs.count) tile(s)…"
            )
            scheduleNextTileBatch()
        }
    }

    private func drawVisibleRegion(seed: WorldSeed, viewState: ViewState, generation: Int) {
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let scaleKey = scaleKey(for: tileBlocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))

        ensureTileAtlas(
            for: seed,
            scaleKey: scaleKey,
            minTileX: minTileX,
            maxTileX: maxTileX,
            minTileZ: minTileZ,
            maxTileZ: maxTileZ
        )
        refreshVisibleStructures(for: viewState)
        drawTileAtlas(for: viewState, on: context)

        var missingJobs: [PendingTileJob] = []
        let centerTileX = Int(floor(viewState.centerX / tileWorldSpan))
        let centerTileZ = Int(floor(viewState.centerZ / tileWorldSpan))

        let coordinates = MapMath.centerFirstTileCoordinates(
            minTileX: minTileX,
            maxTileX: maxTileX,
            minTileZ: minTileZ,
            maxTileZ: maxTileZ,
            centerTileX: centerTileX,
            centerTileZ: centerTileZ
        )
        for (tileX, tileZ) in coordinates {
                let cacheKey = TileCacheKey(
                    seed: seed,
                    scaleKey: scaleKey,
                    tileX: tileX,
                    tileZ: tileZ
                )
                if tileCache[cacheKey] == nil {
                    missingJobs.append(
                        PendingTileJob(
                            generation: generation,
                            seed: seed,
                            viewState: viewState,
                            tileBlocksPerPixel: tileBlocksPerPixel,
                            tileX: tileX,
                            tileZ: tileZ,
                            sampleY: currentSampleY,
                            dimensionID: currentDimensionID,
                            enabledStructureSets: Set(loadedStructureIDs.filter {
                                shouldRenderStructureSet($0, in: viewState)
                            })
                        )
                    )
                }
        }

        pendingTileJobs = missingJobs
        biomeTilesTotal = missingJobs.count
        biomeTilesCompleted = 0
        if missingJobs.isEmpty {
            setBiomeGenerationStatus("Biomes: ready from tile cache.")
        } else {
            setBiomeGenerationStatus("Biomes: 0/\(missingJobs.count) tile(s) ready.")
            setStructureGenerationStatus("Structures: waiting for biome tiles.")
        }
        updateDebugPanel()
    }

    private func scheduleNextTileBatch() {
        if pendingTileJobs.isEmpty {
            scheduleNextTileStructure()
            return
        }
        guard pendingTileTimer == nil else { return }
        pendingTileTimer = JSTimer(millisecondsDelay: 0) { [weak self] in
            self?.pendingTileTimer = nil
            self?.processNextTileBatch()
        }
    }

    private func processNextTileBatch() {
        guard !pendingTileJobs.isEmpty else { return }
        guard inFlightTileJob == nil else { return }
        let workerJob = pendingTileJobs.removeFirst()
        guard workerJob.generation == activeViewGeneration, workerJob.seed == currentSeed,
              workerJob.dimensionID == currentDimensionID else {
            scheduleNextTileBatch()
            return
        }
        inFlightTileJob = workerJob
        let generator = self.tileGenerator
        inFlightTileTask = Task { [weak self] in
            do {
                let result = try await generator.generateBiomeTile(workerJob)
                self?.handleGeneratedTile(result, for: workerJob)
            } catch {
                self?.handleTileGenerationFailure(error, for: workerJob)
            }
        }
        updateDebugPanel()
    }

    private func scheduleNextTileStructure() {
        guard pendingRenderTimer == nil else { return }
        guard inFlightTileJob == nil, pendingTileJobs.isEmpty else { return }
        guard inFlightTileStructureJob == nil else { return }
        guard let seed = currentSeed else { return }
        pendingTileStructureJobs.removeAll { $0.tileJob.seed != seed || $0.tileJob.dimensionID != currentDimensionID }
        guard !pendingTileStructureJobs.isEmpty else {
            setStructureGenerationStatus(
                enabledStructureSetIDs().isEmpty ? "Structures: disabled." : "Structures: ready."
            )
            return
        }

        // Enrich current-view tiles before retained off-screen cache entries.
        let index = pendingTileStructureJobs.firstIndex {
            $0.tileJob.generation == activeViewGeneration
        } ?? pendingTileStructureJobs.startIndex
        let structureJob = pendingTileStructureJobs.remove(at: index)
        inFlightTileStructureJob = structureJob
        let currentRemaining = pendingTileStructureJobs.lazy.filter {
            $0.tileJob.generation == self.activeViewGeneration
        }.count + 1
        setStructureGenerationStatus("Structures: generating \(currentRemaining) tile(s).")
        let generator = tileGenerator
        inFlightTileStructureTask = Task { [weak self] in
            do {
                let result = try await generator.generateStructures(
                    for: structureJob.tileJob,
                    biomeCache: structureJob.biomeCache
                )
                self?.handleGeneratedTileStructures(result, for: structureJob)
            } catch {
                self?.handleTileStructureFailure(error, for: structureJob)
            }
        }
    }

    private func handleGeneratedTileStructures(
        _ result: StructureQueryResult?,
        for structureJob: PendingTileStructureJob
    ) {
        inFlightTileStructureJob = nil
        inFlightTileStructureTask = nil
        let job = structureJob.tileJob
        let key = TileCacheKey(
            seed: job.seed,
            scaleKey: scaleKey(for: job.tileBlocksPerPixel),
            tileX: job.tileX,
            tileZ: job.tileZ
        )
        if let existing = tileCache[key] {
            tileCache[key] = CachedTile(
                width: existing.width,
                height: existing.height,
                palette: existing.palette,
                biomeIndices: existing.biomeIndices,
                structurePoints: result?.points ?? [],
                structureMetrics: result?.metrics ?? StructureProfilingMetrics()
            )
        }
        if job.seed == currentSeed, job.dimensionID == currentDimensionID, let viewState = latestViewState {
            refreshVisibleStructures(for: viewState)
            drawGridOverlay(for: viewState)
        }
        let currentRemaining = pendingTileStructureJobs.lazy.filter {
            $0.tileJob.generation == self.activeViewGeneration
        }.count
        setStructureGenerationStatus(
            currentRemaining == 0
                ? "Structures: ready."
                : "Structures: \(currentRemaining) tile(s) remaining."
        )
        scheduleNextTileStructure()
    }

    private func handleTileStructureFailure(
        _ error: Error,
        for structureJob: PendingTileStructureJob
    ) {
        inFlightTileStructureJob = nil
        inFlightTileStructureTask = nil
        if error is CancellationError, structureJob.tileJob.seed == currentSeed,
           structureJob.tileJob.dimensionID == currentDimensionID {
            pendingTileStructureJobs.append(structureJob)
        } else if structureJob.tileJob.generation == activeViewGeneration {
            setStructureSummary("Failed to locate structures: \(error)", isError: true)
            setStructureGenerationStatus("Structures: failed — \(error)", isError: true)
        }
        if pendingTileJobs.isEmpty {
            scheduleNextTileStructure()
        } else {
            scheduleNextTileBatch()
        }
    }

    private func redrawTileIfCurrent(job: PendingTileJob) {
        guard let currentView = latestViewState else { return }
        guard job.generation == activeViewGeneration else { return }

        let key = TileCacheKey(
            seed: job.seed,
            scaleKey: scaleKey(for: job.tileBlocksPerPixel),
            tileX: job.tileX,
            tileZ: job.tileZ
        )
        drawTileCanvasIntoAtlas(key: key)
        drawTileAtlas(for: currentView, on: context)
        drawGridOverlay(for: currentView)
    }

    private func ensureTileAtlas(
        for seed: WorldSeed,
        scaleKey: Int,
        minTileX: Int,
        maxTileX: Int,
        minTileZ: Int,
        maxTileZ: Int
    ) {
        let margin = 1
        let requiredMinTileX = minTileX - margin
        let requiredMaxTileX = maxTileX + margin
        let requiredMinTileZ = minTileZ - margin
        let requiredMaxTileZ = maxTileZ + margin
        if let tileAtlas,
           tileAtlas.seed == seed,
           tileAtlas.scaleKey == scaleKey,
           tileAtlas.minTileX <= requiredMinTileX,
           tileAtlas.maxTileX >= requiredMaxTileX,
           tileAtlas.minTileZ <= requiredMinTileZ,
           tileAtlas.maxTileZ >= requiredMaxTileZ
        {
            return
        }

        let atlas = TileAtlas(
            seed: seed,
            scaleKey: scaleKey,
            minTileX: requiredMinTileX,
            maxTileX: requiredMaxTileX,
            minTileZ: requiredMinTileZ,
            maxTileZ: requiredMaxTileZ
        )
        preserveTileAtlasAsFallback()
        snapshotCanvas.width = ((atlas.maxTileX - atlas.minTileX + 1) * tileSize).jsValue
        snapshotCanvas.height = ((atlas.maxTileZ - atlas.minTileZ + 1) * tileSize).jsValue
        configureCanvasContext(snapshotContext)
        tileAtlas = atlas

        for tileZ in atlas.minTileZ...atlas.maxTileZ {
            for tileX in atlas.minTileX...atlas.maxTileX {
                drawTileCanvasIntoAtlas(
                    key: TileCacheKey(seed: seed, scaleKey: scaleKey, tileX: tileX, tileZ: tileZ)
                )
            }
        }
    }

    private func drawTileCanvasIntoAtlas(key: TileCacheKey) {
        guard let tileAtlas,
              tileAtlas.seed == key.seed,
              tileAtlas.scaleKey == key.scaleKey,
              key.tileX >= tileAtlas.minTileX,
              key.tileX <= tileAtlas.maxTileX,
              key.tileZ >= tileAtlas.minTileZ,
              key.tileZ <= tileAtlas.maxTileZ
        else {
            return
        }

        let atlasStart = profilingNow()
        guard let sourceCanvas = makeTileCanvas(for: key) else { return }
        _ = snapshotContext.drawImage!(
            sourceCanvas,
            0,
            0,
            sourceCanvas.width,
            sourceCanvas.height,
            (key.tileX - tileAtlas.minTileX) * tileSize,
            (key.tileZ - tileAtlas.minTileZ) * tileSize,
            tileSize,
            tileSize
        )
        // The atlas owns the raster after this copy. Keeping a canvas per tile multiplies
        // backing-store memory at large viewport sizes.
        releaseCanvas(sourceCanvas)
        profilingMetrics.atlasMilliseconds += profilingNow() - atlasStart
    }

    private func drawTileAtlas(for viewState: ViewState, on targetContext: JSObject) {
        let viewportStart = profilingNow()
        targetContext.fillStyle = placeholderColor.jsValue
        _ = targetContext.fillRect!(0, 0, viewState.viewportWidth, viewState.viewportHeight)
        if let fallbackTileAtlas {
            drawAtlas(
                fallbackCanvas,
                atlas: fallbackTileAtlas,
                for: viewState,
                on: targetContext
            )
        }
        if let tileAtlas {
            drawAtlas(snapshotCanvas, atlas: tileAtlas, for: viewState, on: targetContext)
        }
        profilingMetrics.viewportMilliseconds += profilingNow() - viewportStart
    }

    private func drawAtlas(
        _ sourceCanvas: JSObject,
        atlas: TileAtlas,
        for viewState: ViewState,
        on targetContext: JSObject
    ) {
        let tileBlocksPerPixel = Double(atlas.scaleKey) / 1024.0
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let atlasWorldStartX = Double(atlas.minTileX * tileSize) * tileBlocksPerPixel
        let atlasWorldStartZ = Double(atlas.minTileZ * tileSize) * tileBlocksPerPixel
        let sourceX = (worldStartX - atlasWorldStartX) / tileBlocksPerPixel
        let sourceZ = (worldStartZ - atlasWorldStartZ) / tileBlocksPerPixel
        let sourceWidth = Double(viewState.viewportWidth) * viewState.blocksPerPixel / tileBlocksPerPixel
        let sourceHeight = Double(viewState.viewportHeight) * viewState.blocksPerPixel / tileBlocksPerPixel

        _ = targetContext.drawImage!(
            sourceCanvas,
            sourceX,
            sourceZ,
            sourceWidth,
            sourceHeight,
            0,
            0,
            viewState.viewportWidth,
            viewState.viewportHeight
        )
    }

    private func configureCanvasContext(_ targetContext: JSObject) {
        targetContext.imageSmoothingEnabled = false.jsValue
    }

    private func invalidateTileRasters() {
        tileAtlas = nil
        fallbackTileAtlas = nil
        releaseAtlasCanvases()
    }

    private func releaseAtlasCanvases() {
        releaseCanvas(snapshotCanvas)
        releaseCanvas(fallbackCanvas)
    }

    private func releaseCanvas(_ canvas: JSObject) {
        canvas.width = 1.jsValue
        canvas.height = 1.jsValue
    }

    private func preserveTileAtlasAsFallback() {
        guard let tileAtlas else { return }
        let width = (tileAtlas.maxTileX - tileAtlas.minTileX + 1) * tileSize
        let height = (tileAtlas.maxTileZ - tileAtlas.minTileZ + 1) * tileSize
        // This is only a transition aid. Do not duplicate a large atlas in memory.
        guard width * height <= 2_000_000 else {
            fallbackTileAtlas = nil
            releaseCanvas(fallbackCanvas)
            return
        }
        fallbackCanvas.width = width.jsValue
        fallbackCanvas.height = height.jsValue
        configureCanvasContext(fallbackContext)
        _ = fallbackContext.drawImage!(snapshotCanvas, 0, 0)
        fallbackTileAtlas = tileAtlas
    }

    private func makeTileCanvas(for key: TileCacheKey) -> JSObject? {
        guard let tile = tileCache[key] else { return nil }
        let canvas = document.createElement!("canvas").object!
        canvas.width = tile.width.jsValue
        canvas.height = tile.height.jsValue
        guard let canvasContext = canvas.getContext!("2d").object else { return nil }
        configureCanvasContext(canvasContext)
        _ = canvasContext.putImageData!(tileImageData(for: tile, key: key), 0, 0)
        return canvas
    }

    private func tileImageData(
        for tile: CachedTile,
        key cacheKey: TileCacheKey
    ) -> JSObject {
        let rasterStart = profilingNow()
        var pixels = [UInt8](repeating: 255, count: tile.width * tile.height * 4)
        var resolvedColors: [String: BiomeColor] = [:]
        for (index, paletteIndex) in tile.biomeIndices.enumerated() {
            let biomeID = tile.palette[Int(paletteIndex)]
            let color: BiomeColor
            if let cached = resolvedColors[biomeID] {
                color = cached
            } else {
                let resolved = resolvedBiomeColor(for: biomeID)
                resolvedColors[biomeID] = resolved
                color = resolved
            }

            let offset = index * 4
            pixels[offset] = color.red
            pixels[offset + 1] = color.green
            pixels[offset + 2] = color.blue
        }

        let source = JSUInt8ClampedArray(pixels)
        let imageData = JSObject.global.ImageData.object!.new(source, tile.width, tile.height)
        profilingMetrics.rasterMilliseconds += profilingNow() - rasterStart
        return imageData
    }

    private func profilingNow() -> Double {
        guard profilingEnabled else { return 0.0 }
        return JSObject.global.performance.object?.now?().number ?? 0.0
    }

    private func emitProfilingMetrics() {
        guard profilingEnabled else { return }
        let summary =
            "Profile generation \(profilingMetrics.generation): "
                + "sampling=\(String(format: "%.1f", profilingMetrics.sampledBiomeMilliseconds))ms "
                + "palette=\(String(format: "%.1f", profilingMetrics.paletteMilliseconds))ms "
                + "raster=\(String(format: "%.1f", profilingMetrics.rasterMilliseconds))ms "
                + "atlas=\(String(format: "%.1f", profilingMetrics.atlasMilliseconds))ms "
                + "viewport=\(String(format: "%.1f", profilingMetrics.viewportMilliseconds))ms"
        setStatus(summary)
    }

    private func setDragging(_ dragging: Bool) {
        guard let classList = viewport.classList.object else { return }
        if dragging {
            _ = classList.add!("dragging")
        } else {
            _ = classList.remove!("dragging")
        }
    }

    @discardableResult
    private func syncViewportSize() -> Bool {
        guard let rect = viewport.getBoundingClientRect!().object else { return false }
        guard let width = rect.width.number, let height = rect.height.number else { return false }

        let nextWidth = max(1, Int(width.rounded(.down)))
        let nextHeight = max(1, Int(height.rounded(.down)))
        guard nextWidth != viewportWidth || nextHeight != viewportHeight else {
            return false
        }

        viewportWidth = nextWidth
        viewportHeight = nextHeight
        canvas.width = nextWidth.jsValue
        canvas.height = nextHeight.jsValue
        overlayCanvas.width = nextWidth.jsValue
        overlayCanvas.height = nextHeight.jsValue
        configureCanvasContext(context)
        configureCanvasContext(overlayContext)
        return true
    }

    private func currentViewState() -> ViewState {
        ViewState(
            centerX: viewCenterX,
            centerZ: viewCenterZ,
            blocksPerPixel: max(0.125, viewBlocksPerPixel),
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
    }

    private func selectedSampleY() -> Int32 {
        let raw = Int32(yInput.value.string ?? "") ?? defaultSampleY
        let clamped = min(316, max(-64, raw))
        let snapped = Int32((Double(clamped) / 4.0).rounded()) * 4
        yInput.value = snapped.jsValue
        return snapped
    }

    private func zoom(atClientX clientX: Double, clientY: Double, factor: Double) {
        let rectObject = viewport.getBoundingClientRect!().object
        let pointerX = clientX - (rectObject?.left.number ?? 0.0)
        let pointerY = clientY - (rectObject?.top.number ?? 0.0)
        let previousBlocksPerPixel = viewBlocksPerPixel
        let worldX = viewCenterX + (pointerX - Double(viewportWidth) / 2.0) * previousBlocksPerPixel
        let worldZ = viewCenterZ + (pointerY - Double(viewportHeight) / 2.0) * previousBlocksPerPixel

        viewBlocksPerPixel = min(256.0, max(0.125, viewBlocksPerPixel * factor))
        viewCenterX = worldX - (pointerX - Double(viewportWidth) / 2.0) * viewBlocksPerPixel
        viewCenterZ = worldZ - (pointerY - Double(viewportHeight) / 2.0) * viewBlocksPerPixel

        previewCurrentViewIfPossible()
        scheduleVisibleRegionRender()
    }

    private func previewCurrentViewIfPossible() {
        let viewState = currentViewState()
        drawTileAtlas(for: viewState, on: context)
        drawGridOverlay(for: viewState)
    }

    private func setLoading(_ loading: Bool) {
        renderButton.disabled = loading.jsValue
        seedInput.disabled = loading.jsValue
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusElement.innerText = text.jsValue
        statusElement.className = (isError ? "status error" : "status").jsValue
    }

    private func setBiomeGenerationStatus(_ text: String, isError: Bool = false) {
        biomeGenerationStatusElement.innerText = text.jsValue
        biomeGenerationStatusElement.className = (isError ? "status error" : "status").jsValue
    }

    private func setStructureGenerationStatus(_ text: String, isError: Bool = false) {
        structureGenerationStatusElement.innerText = text.jsValue
        structureGenerationStatusElement.className = (isError ? "status error" : "status").jsValue
    }

    private func updateDebugPanel() {
        if let tileX = tileDebugMetrics.tileX,
           let tileZ = tileDebugMetrics.tileZ,
           let blocksPerPixel = tileDebugMetrics.blocksPerPixel
        {
            debugLastTileElement.innerText =
                "(\(tileX), \(tileZ)) at \(String(format: "%.3g", blocksPerPixel)) bpp".jsValue
        } else {
            debugLastTileElement.innerText = "Waiting for a render".jsValue
        }

        debugGenerationTimeElement.innerText = formatDebugDuration(tileDebugMetrics.generationMilliseconds).jsValue
        if let milliseconds = tileDebugMetrics.densityCompilationMilliseconds,
           let backend = tileDebugMetrics.densityCompilationBackend {
            debugDensityCompilationElement.innerText = "\(backend): \(formatDebugDuration(milliseconds))".jsValue
        } else {
            debugDensityCompilationElement.innerText = "Not compiled".jsValue
        }
        debugRenderTimeElement.innerText = formatDebugDuration(tileDebugMetrics.renderMilliseconds).jsValue
        debugPendingTilesElement.innerText = "\(pendingTileJobs.count)".jsValue
        debugCachedTilesElement.innerText = "\(tileCache.count)".jsValue
        debugStructureTimeElement.innerText = formatDebugDuration(structureDebugMetrics.totalMilliseconds).jsValue
        debugStructureSamplingElement.innerText = formatDebugDuration(structureDebugMetrics.samplingMilliseconds).jsValue
        debugStructureValidationElement.innerText = formatDebugDuration(structureDebugMetrics.validationMilliseconds).jsValue
        debugStructureCandidatesElement.innerText = "\(structureDebugMetrics.candidates)".jsValue
        debugStructureAcceptedElement.innerText = "\(structureDebugMetrics.accepted)".jsValue
        debugStructureRejectedElement.innerText = "\(structureDebugMetrics.rejected)".jsValue
        debugStructureCacheHitsElement.innerText = "\(structureDebugMetrics.cacheHits)".jsValue
        if structureDebugMetrics.byStructureType.isEmpty {
            debugStructureTypesElement.innerText = "--".jsValue
        } else {
            let lines = structureDebugMetrics.byStructureType.keys.sorted().map { structureID in
                let metrics = structureDebugMetrics.byStructureType[structureID]!
                let average = metrics.averageMilliseconds
                let formattedAverage = average < 0.1
                    ? String(format: "%.3f", average)
                    : String(format: "%.1f", average)
                return "\(structureID): \(metrics.starts) starts, avg \(formattedAverage) ms"
            }
            debugStructureTypesElement.innerText = lines.joined(separator: "\n").jsValue
        }
    }

    private func formatDebugDuration(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "--" }
        return String(format: "%.1f ms", milliseconds)
    }

    private func fetchText(at path: String, completion: @escaping (Result<String, BrowserAppError>) -> Void) {
        let promise = JSObject.global.fetch!(path).object!

        let responseClosure = JSClosure { [weak self] args in
            guard let self, let response = args.first?.object else {
                completion(.failure(.message("Missing fetch response.")))
                return .undefined
            }

            let textPromise = response.text!().object!
            let textClosure = JSClosure { textArgs in
                completion(.success(textArgs.first?.string ?? ""))
                return .undefined
            }
            let textErrorClosure = JSClosure { [weak self] errorArgs in
                completion(.failure(.message(self?.jsErrorString(errorArgs.first) ?? "Unknown text decode error.")))
                return .undefined
            }
            self.retainedClosures.append(contentsOf: [textClosure, textErrorClosure])
            _ = textPromise.then!(textClosure, textErrorClosure)
            return .undefined
        }

        let errorClosure = JSClosure { [weak self] args in
            completion(.failure(.message(self?.jsErrorString(args.first) ?? "Unknown fetch error.")))
            return .undefined
        }

        retainedClosures.append(contentsOf: [responseClosure, errorClosure])
        _ = promise.then!(responseClosure, errorClosure)
    }

    private func scheduleNextTick(_ body: @escaping () -> Void) {
        pendingTimer = JSTimer(millisecondsDelay: 0) { [weak self] in
            self?.pendingTimer = nil
            body()
        }
    }

    private func scaleKey(for blocksPerPixel: Double) -> Int {
        Int((max(0.125, blocksPerPixel) * 1024.0).rounded())
    }

    private func tileBlocksPerPixel(for blocksPerPixel: Double) -> Double {
        let clamped = min(256.0, max(0.125, blocksPerPixel))
        let exponent = floor(log2(clamped))
        return min(256.0, max(0.125, pow(2.0, exponent)))
    }

    private func pruneTileCache(for seed: WorldSeed, around viewState: ViewState) {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let activeScaleKey = scaleKey(for: tileBlocksPerPixel(for: viewState.blocksPerPixel))

        tileCache = tileCache.filter { key, _ in
            guard key.seed == seed else { return false }

            guard key.scaleKey == activeScaleKey else {
                return false
            }

            let keyBlocksPerPixel = Double(key.scaleKey) / 1024.0
            let tileWorldSpan = Double(tileSize) * keyBlocksPerPixel
            // Keep just a one-tile border for panning. A viewport-sized border retains up to
            // nine full views and dominates memory on large displays.
            let worldMarginX = tileWorldSpan
            let worldMarginZ = tileWorldSpan
            let tileStartX = Double(key.tileX * tileSize) * keyBlocksPerPixel
            let tileStartZ = Double(key.tileZ * tileSize) * keyBlocksPerPixel
            let tileEndX = tileStartX + tileWorldSpan
            let tileEndZ = tileStartZ + tileWorldSpan

            return
                tileEndX >= worldStartX - worldMarginX
                && tileStartX <= worldEndX + worldMarginX
                && tileEndZ >= worldStartZ - worldMarginZ
                && tileStartZ <= worldEndZ + worldMarginZ
        }
    }

    private func reloadStructureEditor(using structureSets: [BrowserStructureSetMetadata]) {
        let structureIDs = structureSets.map(\.id)
        loadedStructureIDs = structureIDs
        let loadedStructureSet = Set(structureIDs)
        structureColors = structureColors.filter { loadedStructureSet.contains($0.key) }
        enabledStructureSets = enabledStructureSets.filter { loadedStructureSet.contains($0.key) }
        structureSetSpacings = [:]
        structureSetFrequencies.removeAll(keepingCapacity: true)
        structureSetStructureIDs = Dictionary(
            uniqueKeysWithValues: structureSets.map { ($0.id, $0.structureIDs) }
        )

        for structureID in structureIDs where structureColors[structureID] == nil {
            structureColors[structureID] = defaultStructureSetColor(for: structureID)
        }
        for structureID in structureIDs where enabledStructureSets[structureID] == nil {
            enabledStructureSets[structureID] = true
        }
        for structureSet in structureSets {
            if let spacing = structureSet.spacing {
                structureSetSpacings[structureSet.id] = spacing
            }
            if structureSet.hasFrequency {
                structureSetFrequencies.insert(structureSet.id)
            }
        }
        renderStructureEditor()
    }

    private func renderStructureEditor() {
        structureRowElements.removeAll(keepingCapacity: true)
        structureListElement.innerHTML = "".jsValue
        guard !loadedStructureIDs.isEmpty else {
            setStructureSummary("No structures are loaded.", isError: false)
            structureEmptyElement.hidden = false.jsValue
            return
        }

        structureEmptyElement.hidden = true.jsValue
        setStructureSummary("Loaded \(loadedStructureIDs.count) structure set(s).", isError: false)
        for structureID in loadedStructureIDs {
            let row = document.createElement!("div").object!
            row.className = "biome-row".jsValue

            let header = document.createElement!("div").object!
            header.className = "biome-row-header".jsValue
            let swatch = document.createElement!("span").object!
            swatch.className = "biome-swatch".jsValue
            _ = header.appendChild!(swatch)
            let name = document.createElement!("span").object!
            name.className = "biome-name".jsValue
            name.innerText = structureID.jsValue
            _ = header.appendChild!(name)
            _ = row.appendChild!(header)

            let enabledInput = document.createElement!("input").object!
            enabledInput.type = "checkbox".jsValue
            enabledInput.className = "structure-enabled-input".jsValue
            enabledInput.title = "Render this structure set".jsValue
            enabledInput.ariaLabel = "Render \(structureID)".jsValue
            let enabledClosure = JSClosure { [weak self, enabledInput] _ in
                self?.applyStructureEnabledChange(for: structureID, enabled: enabledInput.checked.boolean ?? false)
                return .undefined
            }
            retainedClosures.append(enabledClosure)
            _ = enabledInput.addEventListener!("change", enabledClosure)
            _ = row.appendChild!(enabledInput)

            let colorInput = document.createElement!("input").object!
            colorInput.type = "color".jsValue
            colorInput.className = "structure-color-input".jsValue
            let inputClosure = JSClosure { [weak self, colorInput] _ in
                self?.applyStructureColorChange(for: structureID, cssHex: colorInput.value.string ?? "")
                return .undefined
            }
            retainedClosures.append(inputClosure)
            _ = colorInput.addEventListener!("input", inputClosure)
            _ = row.appendChild!(colorInput)
            _ = structureListElement.appendChild!(row)
            structureRowElements[structureID] = StructureRowElements(
                swatch: swatch,
                enabledInput: enabledInput,
                colorInput: colorInput
            )
            syncStructureRow(for: structureID)
        }
    }

    private func applyStructureColorChange(for structureID: String, cssHex: String) {
        guard let color = colorFromCSSHex(cssHex) else { return }
        structureColors[structureID] = color
        syncStructureRow(for: structureID)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
        }
    }

    private func applyStructureEnabledChange(for structureID: String, enabled: Bool) {
        enabledStructureSets[structureID] = enabled
        syncStructureRow(for: structureID)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
            refreshVisibleStructures(for: viewState)
            drawGridOverlay(for: viewState)
        }
    }

    private func resetStructureColorsToDefaults() {
        guard !loadedStructureIDs.isEmpty else {
            setStructureSummary("No structures are loaded.", isError: true)
            return
        }
        for structureID in loadedStructureIDs {
            structureColors[structureID] = defaultStructureSetColor(for: structureID)
            enabledStructureSets[structureID] = true
            syncStructureRow(for: structureID)
        }
        setStructureSummary("Reset \(loadedStructureIDs.count) structure colour(s) to defaults.", isError: false)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
        }
    }

    private func syncStructureRow(for structureID: String) {
        guard let row = structureRowElements[structureID], let color = structureColors[structureID] else { return }
        row.swatch.style.object?.backgroundColor = color.cssHex.jsValue
        row.enabledInput.checked = (enabledStructureSets[structureID] ?? true).jsValue
        row.colorInput.value = color.cssHex.jsValue
    }

    private func setStructureSummary(_ text: String, isError: Bool) {
        structureSummaryElement.innerText = text.jsValue
        structureSummaryElement.className = (isError ? "status error" : "status").jsValue
    }

    private func colorFromCSSHex(_ cssHex: String) -> BiomeColor? {
        guard cssHex.count == 7, cssHex.first == "#" else { return nil }
        guard
            let red = UInt8(cssHex.dropFirst().prefix(2), radix: 16),
            let green = UInt8(cssHex.dropFirst(3).prefix(2), radix: 16),
            let blue = UInt8(cssHex.dropFirst(5).prefix(2), radix: 16)
        else {
            return nil
        }
        return BiomeColor(red: red, green: green, blue: blue)
    }

    private func reloadBiomeEditor(using biomeIDs: [String]) {
        loadedBiomeIDs = biomeIDs

        let loadedBiomeSet = Set(biomeIDs)
        biomeColors = biomeColors.filter { loadedBiomeSet.contains($0.key) }
        biomeColorCache = biomeColorCache.filter { loadedBiomeSet.contains($0.key) }

        for biomeID in biomeIDs where biomeColors[biomeID] == nil {
            let color = vanillaBiomeDefaults[biomeID] ?? generatedBiomeColor(for: biomeID)
            biomeColors[biomeID] = color
            biomeColorCache[biomeID] = color.cssHex
        }

        renderBiomeEditor()
    }

    private func reloadDimensionPicker(using dimensionIDs: [String]) {
        let selectedID = dimensionInput.value.string ?? "minecraft:overworld"
        let availableIDs = dimensionIDs.isEmpty ? ["minecraft:overworld"] : dimensionIDs
        dimensionInput.innerHTML = "".jsValue

        for dimensionID in availableIDs {
            let option = document.createElement!("option").object!
            option.value = dimensionID.jsValue
            option.innerText = dimensionID.jsValue
            _ = dimensionInput.appendChild!(option)
        }

        let restoredID = availableIDs.contains(selectedID) ? selectedID : availableIDs.first
        if let restoredID {
            dimensionInput.value = restoredID.jsValue
        }
    }

    private func renderBiomeEditor() {
        biomeRowElements.removeAll(keepingCapacity: true)
        biomeListElement.innerHTML = "".jsValue

        if loadedBiomeIDs.isEmpty {
            setBiomeSummary("No biomes are loaded.", isError: false)
            biomeEmptyElement.hidden = false.jsValue
            return
        }

        setBiomeSummary(defaultBiomeSummaryText(), isError: false)
        biomeEmptyElement.hidden = true.jsValue

        for biomeID in loadedBiomeIDs {
            let row = makeBiomeRow(for: biomeID)
            biomeRowElements[biomeID] = row.elements
            _ = biomeListElement.appendChild!(row.container)
            syncBiomeRow(for: biomeID)
        }
    }

    private func makeBiomeRow(for biomeID: String) -> (container: JSObject, elements: BiomeRowElements) {
        let row = document.createElement!("div").object!
        row.className = "biome-row".jsValue

        let header = document.createElement!("div").object!
        header.className = "biome-header".jsValue

        let swatch = document.createElement!("div").object!
        swatch.className = "biome-swatch".jsValue
        _ = header.appendChild!(swatch)

        let name = document.createElement!("div").object!
        name.className = "biome-name".jsValue
        name.innerText = biomeID.jsValue
        _ = header.appendChild!(name)
        _ = row.appendChild!(header)

        let colorInput = document.createElement!("input").object!
        colorInput.type = "color".jsValue
        colorInput.className = "structure-color-input".jsValue
        let inputClosure = JSClosure { [weak self, colorInput] _ in
            self?.applyBiomeColorChange(for: biomeID, cssHex: colorInput.value.string ?? "")
            return .undefined
        }
        retainedClosures.append(inputClosure)
        _ = colorInput.addEventListener!("input", inputClosure)
        _ = row.appendChild!(colorInput)

        return (
            row,
            BiomeRowElements(
                swatch: swatch,
                colorInput: colorInput
            )
        )
    }

    private func applyBiomeColorChange(for biomeID: String, cssHex: String) {
        guard let color = colorFromCSSHex(cssHex) else { return }

        guard biomeColors[biomeID] != color else {
            syncBiomeRow(for: biomeID)
            return
        }

        biomeColors[biomeID] = color
        biomeColorCache[biomeID] = color.cssHex
        syncBiomeRow(for: biomeID)
        invalidateTileRasters()
        scheduleVisibleRegionRender()
    }

    private func resetBiomeColorsToDefaults() {
        guard !loadedBiomeIDs.isEmpty else {
            setBiomeSummary("No biomes are loaded.", isError: true)
            return
        }

        for biomeID in loadedBiomeIDs {
            let color = vanillaBiomeDefaults[biomeID] ?? generatedBiomeColor(for: biomeID)
            biomeColors[biomeID] = color
            biomeColorCache[biomeID] = color.cssHex
            syncBiomeRow(for: biomeID)
        }

        setBiomeSummary("Reset \(loadedBiomeIDs.count) biome color(s) to defaults.", isError: false)
        invalidateTileRasters()
        scheduleVisibleRegionRender()
    }

    private func handleBiomeImportSelection() {
        guard let files = biomeImportInput.files.object else { return }
        guard let file = files[0].object else {
            biomeImportInput.value = "".jsValue
            return
        }

        let textPromise = file.text!().object!
        let successClosure = JSClosure { [weak self] args in
            guard let self else { return .undefined }
            self.biomeImportInput.value = "".jsValue
            self.importBiomeColors(from: args.first?.string ?? "")
            return .undefined
        }
        let errorClosure = JSClosure { [weak self] args in
            self?.biomeImportInput.value = "".jsValue
            self?.setBiomeSummary("Failed to import biome colors: \(self?.jsErrorString(args.first) ?? "Unknown file read error.")", isError: true)
            return .undefined
        }
        retainedClosures.append(contentsOf: [successClosure, errorClosure])
        _ = textPromise.then!(successClosure, errorClosure)
    }

    private func importBiomeColors(from text: String) {
        guard !loadedBiomeIDs.isEmpty else {
            setBiomeSummary("No biomes are loaded.", isError: true)
            return
        }

        let loadedBiomeSet = Set(loadedBiomeIDs)
        var applied = 0
        var unknown = 0
        var malformed = 0
        var updatedBiomeIDs: [String] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = String(rawLine).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let components = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard components.count == 4 else {
                malformed += 1
                continue
            }

            let biomeID = namespacedBiomeID(from: String(components[0]))
            guard loadedBiomeSet.contains(biomeID) else {
                unknown += 1
                continue
            }

            guard
                let red = parseBiomeColorComponent(String(components[1])),
                let green = parseBiomeColorComponent(String(components[2])),
                let blue = parseBiomeColorComponent(String(components[3]))
            else {
                malformed += 1
                continue
            }

            let color = BiomeColor(red: red, green: green, blue: blue)
            biomeColors[biomeID] = color
            biomeColorCache[biomeID] = color.cssHex
            updatedBiomeIDs.append(biomeID)
            applied += 1
        }

        for biomeID in Set(updatedBiomeIDs) {
            syncBiomeRow(for: biomeID)
        }

        if applied > 0 {
            invalidateTileRasters()
            scheduleVisibleRegionRender()
        }

        var fragments: [String] = []
        if applied > 0 {
            fragments.append("Imported \(applied) biome color(s).")
        }
        if unknown > 0 {
            fragments.append("Ignored \(unknown) unknown biome entr\(unknown == 1 ? "y" : "ies").")
        }
        if malformed > 0 {
            fragments.append("Skipped \(malformed) malformed line(s).")
        }
        if fragments.isEmpty {
            fragments.append("No biome colors were imported.")
        }

        setBiomeSummary(fragments.joined(separator: " "), isError: applied == 0)
    }

    private func exportBiomeColors(usingCubiomesFormat: Bool) {
        guard !loadedBiomeIDs.isEmpty else {
            setBiomeSummary("No biomes are loaded.", isError: true)
            return
        }

        let lines = loadedBiomeIDs.map { biomeID -> String in
            let color = resolvedBiomeColor(for: biomeID)
            let exportedID: String
            if usingCubiomesFormat, vanillaBiomeDefaults[biomeID] != nil, biomeID.hasPrefix("minecraft:") {
                exportedID = String(biomeID.dropFirst("minecraft:".count))
            } else {
                exportedID = biomeID
            }

            if usingCubiomesFormat {
                return "\(exportedID) \(color.red) \(color.green) \(color.blue)"
            } else {
                return String(format: "\(exportedID) 0x%02X 0x%02X 0x%02X", color.red, color.green, color.blue)
            }
        }

        let contents = lines.joined(separator: "\n") + "\n"
        let encodedContents = JSObject.global.encodeURIComponent!(contents).string ?? ""
        let anchor = document.createElement!("a").object!
        anchor.href = "data:text/plain;charset=utf-8,\(encodedContents)".jsValue
        anchor.download = (usingCubiomesFormat ? "biome-colors-cubiomes.txt" : "biome-colors.txt").jsValue
        _ = document.body.object?.appendChild!(anchor)
        _ = anchor.click!()
        _ = document.body.object?.removeChild!(anchor)

        setBiomeSummary("Exported \(loadedBiomeIDs.count) biome color(s)\(usingCubiomesFormat ? " in Cubiomes format." : ".")", isError: false)
    }

    private func namespacedBiomeID(from rawID: String) -> String {
        rawID.contains(":") ? rawID : "minecraft:\(rawID)"
    }

    private func parseBiomeColorComponent(_ raw: String) -> UInt8? {
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            guard let value = UInt8(raw.dropFirst(2), radix: 16), value >= 0, value <= 255 else {
                return nil
            }
            return UInt8(value)
        }
        guard let value = Int(raw), value >= 0, value <= 255 else {
            return nil
        }
        return UInt8(value)
    }

    private func defaultBiomeSummaryText() -> String {
        "Loaded \(loadedBiomeIDs.count) biome(s). Edit colour per biome."
    }

    private func setBiomeSummary(_ text: String, isError: Bool) {
        biomeSummaryElement.innerText = text.jsValue
        biomeSummaryElement.className = (isError ? "status error" : "status").jsValue
    }

    private func drawGridOverlay(for viewState: ViewState) {
        _ = overlayContext.clearRect!(0, 0, viewState.viewportWidth, viewState.viewportHeight)
        drawTileGrid(for: viewState, on: overlayContext)
        drawTileGridLabels(for: viewState, on: overlayContext)
        drawStructurePoints(for: viewState)
        drawLootContainers(for: viewState)
    }

    private func scheduleStructureQuery(for seed: WorldSeed, viewState: ViewState, generation: Int) {
        requestedStructureGeneration = generation
        guard inFlightStructureTask == nil else { return }

        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let query = StructureQuery(
            seed: seed,
            dimensionID: currentDimensionID,
            minX: clampedWorldCoordinate(floor(worldStartX)),
            maxX: clampedWorldCoordinate(ceil(worldEndX)),
            minZ: clampedWorldCoordinate(floor(worldStartZ)),
            maxZ: clampedWorldCoordinate(ceil(worldEndZ)),
            enabledStructureSets: enabledStructureSetIDs(),
            minimumSpacingBlocks: minimumStructureSpacingBlocks(for: viewState)
        )
        let tileGenerator = self.tileGenerator
        inFlightStructureTask = Task { [weak self] in
            do {
                let resultMaybe = try await tileGenerator.structures(in: query)
                guard let result = resultMaybe else { return }
                self?.handleStructureQuery(result, for: generation, seed: seed)
            } catch {
                self?.handleStructureQueryFailure(error, for: generation)
            }
        }
    }

    private func handleStructureQuery(_ result: StructureQueryResult, for generation: Int, seed: WorldSeed) {
        inFlightStructureTask = nil
        guard generation == activeViewGeneration, seed == currentSeed else {
            scheduleLatestStructureQueryIfNeeded()
            return
        }
        structureDebugMetrics = result.metrics
        updateDebugPanel()
        visibleStructurePoints = result.points
        setStructureSummary("Showing \(result.points.count) structure start\(result.points.count == 1 ? "" : "s") in this view.", isError: false)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
            scheduleConcentricStructureQuery(for: seed, viewState: viewState, generation: generation)
        }
    }

    private func scheduleConcentricStructureQuery(for seed: WorldSeed, viewState: ViewState, generation: Int) {
        guard inFlightConcentricStructureTask == nil else { return }
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let query = StructureQuery(
            seed: seed,
            dimensionID: currentDimensionID,
            minX: clampedWorldCoordinate(floor(worldStartX)),
            maxX: clampedWorldCoordinate(ceil(worldEndX)),
            minZ: clampedWorldCoordinate(floor(worldStartZ)),
            maxZ: clampedWorldCoordinate(ceil(worldEndZ)),
            enabledStructureSets: enabledStructureSetIDs(),
            minimumSpacingBlocks: minimumStructureSpacingBlocks(for: viewState)
        )
        let tileGenerator = self.tileGenerator
        inFlightConcentricStructureTask = Task { [weak self] in
            do {
                let resultMaybe = try await tileGenerator.concentricStructures(in: query)
                guard let result = resultMaybe else { return }
                self?.handleConcentricStructureQuery(result, for: generation, seed: seed)
            } catch {
                self?.handleConcentricStructureQueryFailure(error, for: generation)
            }
        }
    }

    private func handleConcentricStructureQuery(_ result: StructureQueryResult, for generation: Int, seed: WorldSeed) {
        inFlightConcentricStructureTask = nil
        guard generation == activeViewGeneration, seed == currentSeed else { return }
        structureDebugMetrics.merge(result.metrics)
        updateDebugPanel()
        visibleStructurePoints = Array(Set(visibleStructurePoints).union(result.points)).sorted {
            ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID)
        }
        setStructureSummary("Showing \(visibleStructurePoints.count) structure start\(visibleStructurePoints.count == 1 ? "" : "s") in this view.", isError: false)
        if let viewState = latestViewState {
            drawGridOverlay(for: viewState)
        }
    }

    private func handleConcentricStructureQueryFailure(_ error: Error, for generation: Int) {
        inFlightConcentricStructureTask = nil
        guard generation == activeViewGeneration else { return }
        // Random-spread structures are already rendered. Keep that useful result if the optional
        // ring enumeration cannot complete for a particular datapack.
        setStructureSummary("Showing \(visibleStructurePoints.count) starts; ring structures failed to locate: \(error)", isError: true)
    }

    private func handleStructureQueryFailure(_ error: Error, for generation: Int) {
        inFlightStructureTask = nil
        guard generation == activeViewGeneration else {
            scheduleLatestStructureQueryIfNeeded()
            return
        }
        setStructureSummary("Failed to locate structures: \(error)", isError: true)
    }

    private func scheduleLatestStructureQueryIfNeeded() {
        guard let seed = currentSeed, let viewState = latestViewState else { return }
        scheduleStructureQuery(for: seed, viewState: viewState, generation: activeViewGeneration)
    }

    private func clampedWorldCoordinate(_ value: Double) -> Int32 {
        if value <= Double(Int32.min) { return Int32.min }
        if value >= Double(Int32.max) { return Int32.max }
        return Int32(value)
    }

    private func drawStructurePoints(for viewState: ViewState) {
        guard !visibleStructurePoints.isEmpty else { return }
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let pointSize = max(4.0, min(9.0, 6.0 / sqrt(viewState.blocksPerPixel)))
        for point in visibleStructurePoints {
        guard shouldRenderStructureSet(point.setID, in: viewState) else { continue }
            let screenX = (Double(point.x) - worldStartX) / viewState.blocksPerPixel
            let screenZ = (Double(point.z) - worldStartZ) / viewState.blocksPerPixel
            guard screenX >= -pointSize, screenX <= Double(viewState.viewportWidth) + pointSize,
                  screenZ >= -pointSize, screenZ <= Double(viewState.viewportHeight) + pointSize
            else {
                continue
            }
            overlayContext.fillStyle = "#000000".jsValue
            _ = overlayContext.fillRect!(
                screenX - pointSize / 2.0 - 1.0,
                screenZ - pointSize / 2.0 - 1.0,
                pointSize + 2.0,
                pointSize + 2.0
            )
            overlayContext.fillStyle = structureColor(for: point.setID).cssHex.jsValue
            _ = overlayContext.fillRect!(screenX - pointSize / 2.0, screenZ - pointSize / 2.0, pointSize, pointSize)
        }
    }

    private func refreshVisibleStructures(for viewState: ViewState) {
        guard let seed = currentSeed else { return }
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let scaleKey = scaleKey(for: tileBlocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))
        let query = StructureQuery(
            seed: seed,
            dimensionID: currentDimensionID,
            minX: clampedWorldCoordinate(floor(worldStartX)),
            maxX: clampedWorldCoordinate(ceil(worldEndX)),
            minZ: clampedWorldCoordinate(floor(worldStartZ)),
            maxZ: clampedWorldCoordinate(ceil(worldEndZ)),
            enabledStructureSets: [],
            minimumSpacingBlocks: 0
        )

        var points = Set<StructurePoint>()
        var metrics = StructureProfilingMetrics()
        for tileZ in minTileZ...maxTileZ {
            for tileX in minTileX...maxTileX {
                let key = TileCacheKey(seed: seed, scaleKey: scaleKey, tileX: tileX, tileZ: tileZ)
                guard let tile = tileCache[key] else { continue }
                metrics.merge(tile.structureMetrics)
                for point in tile.structurePoints
                where point.x >= query.minX && point.x <= query.maxX
                      && point.z >= query.minZ && point.z <= query.maxZ
                      &&
                      shouldRenderStructureSet(point.setID, in: viewState) {
                    points.insert(point)
                }
            }
        }
        visibleStructurePoints = points.sorted {
            ($0.z, $0.x, $0.setID, $0.structureID) < ($1.z, $1.x, $1.setID, $1.structureID)
        }
        structureDebugMetrics = metrics
        updateDebugPanel()
        setStructureSummary("Showing \(visibleStructurePoints.count) structure start\(visibleStructurePoints.count == 1 ? "" : "s") in this view.", isError: false)
    }

    private func drawLootContainers(for viewState: ViewState) {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let size = max(5.0, min(11.0, 7.0 / sqrt(viewState.blocksPerPixel)))
        for container in visibleLootContainers {
            let screenX = (Double(container.x) - worldStartX) / viewState.blocksPerPixel
            let screenZ = (Double(container.z) - worldStartZ) / viewState.blocksPerPixel
            overlayContext.fillStyle = "#000000".jsValue
            _ = overlayContext.fillRect!(screenX - size / 2.0 - 1.5, screenZ - size / 2.0 - 1.5, size + 3.0, size + 3.0)
            overlayContext.fillStyle = "#FFF2A8".jsValue
            _ = overlayContext.fillRect!(screenX - size / 2.0, screenZ - size / 2.0, size, size)
        }
    }

    private func drawTileGrid(for viewState: ViewState, on targetContext: JSObject) {
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))

        targetContext.fillStyle = gridLineColor.jsValue

        for tileX in minTileX...maxTileX + 1 {
            let screenX = Int(floor((Double(tileX * tileSize) * tileBlocksPerPixel - worldStartX) / viewState.blocksPerPixel))
            _ = targetContext.fillRect!(screenX, 0, 1, viewState.viewportHeight)
        }

        for tileZ in minTileZ...maxTileZ + 1 {
            let screenZ = Int(floor((Double(tileZ * tileSize) * tileBlocksPerPixel - worldStartZ) / viewState.blocksPerPixel))
            _ = targetContext.fillRect!(0, screenZ, viewState.viewportWidth, 1)
        }
    }

    private func drawTileGridLabels(for viewState: ViewState, on targetContext: JSObject) {
        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldEndX = worldStartX + Double(viewState.viewportWidth) * viewState.blocksPerPixel
        let worldEndZ = worldStartZ + Double(viewState.viewportHeight) * viewState.blocksPerPixel
        let minTileX = Int(floor(worldStartX / tileWorldSpan))
        let maxTileX = Int(floor((worldEndX - 0.0001) / tileWorldSpan))
        let minTileZ = Int(floor(worldStartZ / tileWorldSpan))
        let maxTileZ = Int(floor((worldEndZ - 0.0001) / tileWorldSpan))

        targetContext.fillStyle = gridLabelColor.jsValue
        targetContext.font = "11px SFMono-Regular, Menlo, monospace".jsValue
        targetContext.textBaseline = "top".jsValue

        for tileZ in minTileZ...maxTileZ + 1 {
            let worldGridZ = Double(tileZ * tileSize) * tileBlocksPerPixel
            let screenZ = Int(floor((worldGridZ - worldStartZ) / viewState.blocksPerPixel))
            guard screenZ < viewState.viewportHeight else { continue }

            for tileX in minTileX...maxTileX + 1 {
                let worldGridX = Double(tileX * tileSize) * tileBlocksPerPixel
                let screenX = Int(floor((worldGridX - worldStartX) / viewState.blocksPerPixel))
                guard screenX < viewState.viewportWidth else { continue }

                let label = "\(formattedGridCoordinate(worldGridX)), \(formattedGridCoordinate(worldGridZ))"
                _ = targetContext.fillText!(label, screenX + 4, screenZ + 4)
            }
        }
    }

    private func formattedGridCoordinate(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_001 {
            return String(Int(rounded))
        }

        var text = String(format: "%.2f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) {
            text.removeLast()
        }
        return text
    }

    private func updateTooltip(forClientX clientX: Double, clientY: Double) {
        let viewState = currentViewState()
        let local = localPointerPosition(clientX: clientX, clientY: clientY)
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let worldX = worldStartX + local.x * viewState.blocksPerPixel
        let worldZ = worldStartZ + local.y * viewState.blocksPerPixel
        let blockX = Int(floor(worldX))
        let blockZ = Int(floor(worldZ))
        let container = lootContainer(nearScreenX: local.x, screenZ: local.y, in: viewState)
        let structure = container == nil
            ? structurePoint(nearScreenX: local.x, screenZ: local.y, in: viewState)
            : nil
        commonBase.renderTooltip(
            biome: biomeNameAt(worldX: worldX, worldZ: worldZ, in: viewState),
            blockX: blockX,
            blockZ: blockZ,
            structure: structure.map {
                MapStructurePresentation(setID: $0.setID, structureID: $0.structureID, x: $0.x, z: $0.z)
            },
            container: container.map {
                MapLootPresentation(
                    block: $0.block, lootTable: $0.lootTable, x: $0.x, y: $0.y, z: $0.z, items: $0.loot
                )
            },
            screenX: local.x,
            screenY: local.y
        )
    }

    private func hideTooltip() {
        commonBase.hideTooltip()
    }

    private func selectMapItem(atClientX clientX: Double, clientY: Double) {
        let viewState = currentViewState()
        let local = localPointerPosition(clientX: clientX, clientY: clientY)
        if let container = lootContainer(nearScreenX: local.x, screenZ: local.y, in: viewState) {
            showLootPage()
            selectLootContainer(container)
            return
        }
        selectStructure(atClientX: clientX, clientY: clientY)
    }

    private func selectStructure(atClientX clientX: Double, clientY: Double) {
        guard let seed = currentSeed else { return }
        let viewState = currentViewState()
        let local = localPointerPosition(clientX: clientX, clientY: clientY)
        guard let structure = structurePoint(nearScreenX: local.x, screenZ: local.y, in: viewState) else { return }
        let generation = activeViewGeneration
        let generator = self.tileGenerator
        activeLootRequest += 1
        let requestID = activeLootRequest
        visibleLootContainers.removeAll(keepingCapacity: true)
        activeLootStructure = structure
        renderLootPanel(message: "Generating loot for \(structure.structureID)…")
        showLootPage()
        // This method is entered directly from a JavaScript event callback. Submit the CPU work
        // explicitly to the dedicated executor; relying on an implicit actor hop here trips the
        // Swift WASM runtime's executor precondition before `loot` can begin.
        let workerTask = generator.scheduleLoot(for: structure, seed: seed)
        inFlightLootTask = Task { @MainActor [weak self] in
            do {
                let containers = try await workerTask.value
                guard let self,
                      requestID == self.activeLootRequest,
                      generation == self.activeViewGeneration,
                      seed == self.currentSeed
                else { return }
                if containers.isEmpty {
                    self.commonBase.render(loot: [], message: "This structure has no supported loot containers.")
                } else {
                    self.commonBase.render(loot: containers.map {
                        MapLootPresentation(
                            block: $0.block, lootTable: $0.lootTable, x: $0.x, y: $0.y, z: $0.z, items: $0.loot
                        )
                    })
                }
            } catch {
                guard let self, requestID == self.activeLootRequest else { return }
                self.commonBase.render(loot: [], message: "Could not generate structure loot: \(error)", isError: true)
            }
        }
    }

    private func showLootPage() {
        _ = JSObject.global.dappermapShowPage?("loot".jsValue)
    }

    private func renderLootPanel(message: String?, isError: Bool = false) {
        lootInfoElement.hidden = false.jsValue
        lootContainerDetails.removeAll(keepingCapacity: true)
        lootListElement.innerHTML = "".jsValue
        lootMessageElement.innerText = (message ?? "").jsValue
        lootMessageElement.hidden = (message == nil).jsValue
        lootMessageElement.className = (isError ? "status error" : "status").jsValue
        guard !visibleLootContainers.isEmpty else { return }
        let normalizedFilter = lootFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredContainers = normalizedFilter.isEmpty
            ? visibleLootContainers
            : visibleLootContainers.filter { container in
                container.loot.contains { $0.lowercased().contains(normalizedFilter) }
            }
        if filteredContainers.isEmpty {
            let empty = document.createElement!("p").object!
            empty.className = "status".jsValue
            empty.innerText = "No containers contain \(lootFilter).".jsValue
            _ = lootListElement.appendChild!(empty)
            return
        }
        for container in filteredContainers {
            let details = document.createElement!("details").object!
            details.className = "loot-container".jsValue
            let summary = document.createElement!("summary").object!
            summary.innerText = "\(container.block) at (\(container.x), \(container.y), \(container.z))".jsValue
            _ = details.appendChild!(summary)
            let items = document.createElement!("ul").object!
            items.className = "loot-items".jsValue
            for item in container.loot {
                let row = document.createElement!("li").object!
                row.innerText = item.jsValue
                if !normalizedFilter.isEmpty, item.lowercased().contains(normalizedFilter) {
                    row.className = "loot-item-match".jsValue
                }
                _ = items.appendChild!(row)
            }
            if container.loot.isEmpty {
                let row = document.createElement!("li").object!
                row.innerText = "No resolved items".jsValue
                _ = items.appendChild!(row)
            }
            _ = details.appendChild!(items)
            _ = lootListElement.appendChild!(details)
            lootContainerDetails[container] = details
        }
    }

    private func selectLootContainer(_ container: LootContainerPoint) {
        guard let details = lootContainerDetails[container] else { return }
        details.open = true.jsValue
        _ = details.scrollIntoView?()
    }

    private func localPointerPosition(clientX: Double, clientY: Double) -> (x: Double, y: Double) {
        let rectObject = viewport.getBoundingClientRect!().object
        let localX = clientX - (rectObject?.left.number ?? 0.0)
        let localY = clientY - (rectObject?.top.number ?? 0.0)
        return (
            x: min(max(0.0, localX), Double(viewportWidth)),
            y: min(max(0.0, localY), Double(viewportHeight))
        )
    }

    private func biomeNameAt(worldX: Double, worldZ: Double, in viewState: ViewState) -> String? {
        guard let seed = currentSeed else { return nil }

        let tileBlocksPerPixel = tileBlocksPerPixel(for: viewState.blocksPerPixel)
        let tileWorldSpan = Double(tileSize) * tileBlocksPerPixel
        let tileX = Int(floor(worldX / tileWorldSpan))
        let tileZ = Int(floor(worldZ / tileWorldSpan))
        let key = TileCacheKey(
            seed: seed,
            scaleKey: scaleKey(for: tileBlocksPerPixel),
            tileX: tileX,
            tileZ: tileZ
        )
        guard let tile = tileCache[key] else { return nil }

        let tileWorldStartX = Double(tileX * tileSize) * tileBlocksPerPixel
        let tileWorldStartZ = Double(tileZ * tileSize) * tileBlocksPerPixel
        // Raster tiles may have fewer samples than their 256-pixel display size. Derive the
        // actual world-space sample stride rather than assuming it is the tile BPP.
        let sampleStrideX = tileWorldSpan / Double(tile.width)
        let sampleStrideZ = tileWorldSpan / Double(tile.height)
        let localX = min(max(Int(floor((worldX - tileWorldStartX) / sampleStrideX)), 0), tile.width - 1)
        let localZ = min(max(Int(floor((worldZ - tileWorldStartZ) / sampleStrideZ)), 0), tile.height - 1)
        return tile.palette[Int(tile.biomeIndices[localZ * tile.width + localX])]
    }

    private func structurePoint(nearScreenX screenX: Double, screenZ: Double, in viewState: ViewState) -> StructurePoint? {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let hitRadius = max(6.0, min(11.0, 7.0 / sqrt(viewState.blocksPerPixel)))
        return visibleStructurePoints.filter { shouldRenderStructureSet($0.setID, in: viewState) }.min { lhs, rhs in
            let lhsX = (Double(lhs.x) - worldStartX) / viewState.blocksPerPixel
            let lhsZ = (Double(lhs.z) - worldStartZ) / viewState.blocksPerPixel
            let rhsX = (Double(rhs.x) - worldStartX) / viewState.blocksPerPixel
            let rhsZ = (Double(rhs.z) - worldStartZ) / viewState.blocksPerPixel
            let lhsDistance = (lhsX - screenX) * (lhsX - screenX) + (lhsZ - screenZ) * (lhsZ - screenZ)
            let rhsDistance = (rhsX - screenX) * (rhsX - screenX) + (rhsZ - screenZ) * (rhsZ - screenZ)
            return lhsDistance < rhsDistance
        }.flatMap { point in
            let pointX = (Double(point.x) - worldStartX) / viewState.blocksPerPixel
            let pointZ = (Double(point.z) - worldStartZ) / viewState.blocksPerPixel
            let distanceSquared = (pointX - screenX) * (pointX - screenX) + (pointZ - screenZ) * (pointZ - screenZ)
            return distanceSquared <= hitRadius * hitRadius ? point : nil
        }
    }

    private func lootContainer(nearScreenX screenX: Double, screenZ: Double, in viewState: ViewState) -> LootContainerPoint? {
        let worldStartX = viewState.centerX - Double(viewState.viewportWidth) * viewState.blocksPerPixel / 2.0
        let worldStartZ = viewState.centerZ - Double(viewState.viewportHeight) * viewState.blocksPerPixel / 2.0
        let radius = max(7.0, min(13.0, 8.0 / sqrt(viewState.blocksPerPixel)))
        return visibleLootContainers.min { lhs, rhs in
            let lhsDistance = pow((Double(lhs.x) - worldStartX) / viewState.blocksPerPixel - screenX, 2) + pow((Double(lhs.z) - worldStartZ) / viewState.blocksPerPixel - screenZ, 2)
            let rhsDistance = pow((Double(rhs.x) - worldStartX) / viewState.blocksPerPixel - screenX, 2) + pow((Double(rhs.z) - worldStartZ) / viewState.blocksPerPixel - screenZ, 2)
            return lhsDistance < rhsDistance
        }.flatMap { container in
            let x = (Double(container.x) - worldStartX) / viewState.blocksPerPixel
            let z = (Double(container.z) - worldStartZ) / viewState.blocksPerPixel
            return (x - screenX) * (x - screenX) + (z - screenZ) * (z - screenZ) <= radius * radius ? container : nil
        }
    }

    private func syncBiomeRow(for biomeID: String) {
        guard let row = biomeRowElements[biomeID] else { return }
        let color = resolvedBiomeColor(for: biomeID)
        row.swatch.style.object?.backgroundColor = color.cssHex.jsValue
        row.colorInput.value = color.cssHex.jsValue
    }

    private func resolvedBiomeColor(for biomeID: String) -> BiomeColor {
        if let color = biomeColors[biomeID] {
            return color
        }

        let color = vanillaBiomeDefaults[biomeID] ?? generatedBiomeColor(for: biomeID)
        biomeColors[biomeID] = color
        biomeColorCache[biomeID] = color.cssHex
        return color
    }

    private func generatedBiomeColor(for biomeID: String) -> BiomeColor {
        var hash: UInt32 = 2166136261
        for byte in biomeID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }

        return BiomeColor(
            red: UInt8(64 + (hash & 0x7F)),
            green: UInt8(64 + ((hash >> 7) & 0x7F)),
            blue: UInt8(64 + ((hash >> 14) & 0x7F))
        )
    }

    private func generatedStructureColor(for structureID: String) -> BiomeColor {
        var hash: UInt32 = 2166136261
        for byte in structureID.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return BiomeColor(
            red: UInt8(80 + (hash & 0x6F)),
            green: UInt8(80 + ((hash >> 8) & 0x6F)),
            blue: UInt8(80 + ((hash >> 16) & 0x6F))
        )
    }

    private func parseSeed(_ raw: String) -> WorldSeed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let signed = Int64(trimmed) {
            return UInt64(bitPattern: signed)
        }
        return UInt64(trimmed)
    }

    private func displaySeed(_ seed: WorldSeed) -> String {
        String(Int64(bitPattern: seed))
    }

    private func jsErrorString(_ value: JSValue?) -> String {
        guard let value else { return "Unknown JavaScript error." }
        if let text = value.string, !text.isEmpty {
            return text
        }
        if
            let jsonObject = JSObject.global.JSON.object,
            let json = jsonObject.stringify?(value).string,
            !json.isEmpty
        {
            return json
        }
        return "Unknown JavaScript error."
    }

    private func describe(_ error: BrowserAppError) -> String {
        switch error {
        case .message(let message):
            return message
        }
    }

    private func color(for biomeID: String) -> String {
        if let cached = biomeColorCache[biomeID] {
            return cached
        }

        let resolvedColor = resolvedBiomeColor(for: biomeID).cssHex
        biomeColorCache[biomeID] = resolvedColor
        return resolvedColor
    }

    private func structureColor(for structureID: String) -> BiomeColor {
        if let color = structureColors[structureID] {
            return color
        }
        let color = vanillaStructureDefaults[structureID] ?? generatedStructureColor(for: structureID)
        structureColors[structureID] = color
        return color
    }

    private func defaultStructureSetColor(for structureSetID: String) -> BiomeColor {
        if let structureID = structureSetStructureIDs[structureSetID]?.first(where: { vanillaStructureDefaults[$0] != nil }),
           let color = vanillaStructureDefaults[structureID]
        {
            return color
        }
        return generatedStructureColor(for: structureSetID)
    }

    private func enabledStructureSetIDs() -> Set<String> {
        Set(loadedStructureIDs.filter { enabledStructureSets[$0] ?? true })
    }

    private func minimumStructureSpacingBlocks(for viewState: ViewState) -> Double {
        Double(tileSize) * tileBlocksPerPixel(for: viewState.blocksPerPixel) / 8.0
    }

    private func shouldRenderStructureSet(_ structureSetID: String, in viewState: ViewState) -> Bool {
        guard enabledStructureSets[structureSetID] ?? true else { return false }
        guard let spacing = structureSetSpacings[structureSetID] else { return true }
        let worldSpacing = Double(spacing) * 16.0
        let effectiveSpacing = structureSetFrequencies.contains(structureSetID)
            ? max(worldSpacing, minimumFrequencyStructureWorldSpacing)
            : worldSpacing
        return effectiveSpacing >= minimumStructureSpacingBlocks(for: viewState)
    }

    // MARK: DapperMapPlatform

    func render(tile: MapTilePresentation) {
        guard tile.generation == activeViewGeneration,
              UInt64(bitPattern: tile.seed) == currentSeed,
              let viewState = latestViewState
        else { return }
        let key = TileCacheKey(
            seed: UInt64(bitPattern: tile.seed),
            scaleKey: tile.scaleKey,
            tileX: tile.tileX,
            tileZ: tile.tileZ
        )
        drawTileCanvasIntoAtlas(key: key)
        drawTileAtlas(for: viewState, on: context)
        drawGridOverlay(for: viewState)
    }

    func render(tooltip: MapTooltipPresentation?) {
        guard let tooltip else {
            tooltipElement.hidden = true.jsValue
            return
        }
        tooltipElement.innerText = tooltip.text.jsValue
        tooltipElement.hidden = false.jsValue
        tooltipElement.style.object?.left = "\(Int(tooltip.screenX.rounded(.down)) + 14)px".jsValue
        tooltipElement.style.object?.top = "\(Int(tooltip.screenY.rounded(.down)) + 14)px".jsValue
    }

    func render(sidebar: SidebarPresentation) {
        guard let select = document.getElementById!("page-select").object else { return }
        let selected = select.value.string ?? "map"
        select.innerHTML = "".jsValue
        for tab in sidebar.tabs {
            let option = document.createElement!("option").object!
            option.value = tab.id.jsValue
            option.innerText = tab.title.jsValue
            _ = select.appendChild!(option)
        }
        select.value = selected.jsValue
        if let help = sidebar.tabs.first(where: { $0.id == "loot" })?.fields.first,
           let element = document.querySelector!(".structure-help").object {
            element.innerText = help.value.jsValue
        }
    }

    func render(loot: [MapLootPresentation], message: String?, isError: Bool) {
        visibleLootContainers = loot.map {
            LootContainerPoint(
                block: $0.block,
                lootTable: $0.lootTable,
                x: $0.x,
                y: $0.y,
                z: $0.z,
                loot: $0.items
            )
        }
        drawGridOverlay(for: currentViewState())
        renderLootPanel(message: message, isError: isError)
    }

    func render(status: String, isError: Bool) {
        setStatus(status, isError: isError)
    }
}

/// Starts the browser frontend without exposing its JavaScriptKit implementation to callers.
public func startBrowserApp() {
    JavaScriptEventLoop.installGlobalExecutor()
    Task {
        do {
            guard JSObject.global.crossOriginIsolated.boolean == true else {
                throw BrowserAppError.message(
                    "Worker threads require a cross-origin-isolated page. Serve with Scripts/serve.py so COOP and COEP headers are present."
                )
            }
            // A worker either starts almost immediately or cannot start at all. Do not strand
            // the app in JavaScriptKit's default three-second retry when setup is invalid.
            let tileExecutor = try await WebWorkerDedicatedExecutor(
                timeout: .milliseconds(250),
                checkInterval: .milliseconds(1)
            )
            let samplingBackend = await MainActor.run {
                webKitNeedsScalarTileSampling() ? TileSamplingBackend.scalar : .nestedWASM
            }
            let tileGenerator = TileGenerationService(
                serialExecutor: .dedicated(tileExecutor),
                samplingBackend: samplingBackend
            )
            await MainActor.run {
                let browserApp = BrowserApp(tileGenerator: tileGenerator)
                BrowserAppLifetime.app = browserApp
                browserApp.start()
            }
        } catch {
            await MainActor.run {
                let document = JSObject.global.document
                document.getElementById("status").innerText =
                    "Failed to start tile generation worker: \(error)".jsValue
                document.getElementById("status").className = "status error".jsValue
            }
        }
    }
}

@MainActor
private enum BrowserAppLifetime {
    static var app: AnyObject?
}
#endif
