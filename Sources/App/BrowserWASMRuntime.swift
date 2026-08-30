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
struct BiomeRowElements {
    let swatch: JSObject
    let colorInput: JSObject
}

struct StructureRowElements {
    let swatch: JSObject
    let enabledInput: JSObject
    let colorInput: JSObject
}

private final class JSObjectSendableBox: @unchecked Sendable {
    let object: JSObject

    init(_ object: JSObject) {
        self.object = object
    }
}

/// Instantiates DPReader's nested modules in the browser's native WebAssembly engine.
final class BrowserWASMRuntime: WASMRuntime, @unchecked Sendable {
    private var retainedImportClosures: [JSClosure] = []

    var supportsClimateFunctions: Bool { true }

    deinit {
        invalidate()
    }

    func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation {
        let bridge = makeDensityImports(imports)
        let exportFunction = try instantiate(
            module: module,
            exportName: exportName,
            imports: bridge.object
        )
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)

        return { x, y, z in
            exportBox.object(x, y, z).number ?? 0.0
        }
    }

    func instantiateClimateFunctions(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMClimateInvocation {
        let bridge = makeDensityImports(imports)
        let exportFunction = try instantiate(
            module: module,
            exportName: exportName,
            imports: bridge.object
        )
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)

        return { x, y, z in
            let values = exportBox.object(x, y, z).object
            return WASMClimateSample(
                temperature: values?[0].number ?? 0.0,
                humidity: values?[1].number ?? 0.0,
                continentalness: values?[2].number ?? 0.0,
                erosion: values?[3].number ?? 0.0,
                weirdness: values?[4].number ?? 0.0,
                depth: values?[5].number ?? 0.0
            )
        }
    }

    func instantiateDensityFunctionBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionBulkInvocation {
        let bridge = makeDensityImports(imports)
        let exports = try instantiateExports(module: module, imports: bridge.object)
        guard
            let exportFunction = exports[exportName].object,
            let memory = exports[memoryExportName].object
        else {
            throw BrowserAppError.message("WASM bulk module is missing a required export.")
        }
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)
        let memoryBox = JSObjectSendableBox(memory)

        return { x, y, z, output in
            let byteOffset = Int(exportBox.object(x, y, z).number ?? 0.0)
            guard let buffer = memoryBox.object.buffer.object else { return }
            let values = JSObject.global.Float64Array.object!.new(
                buffer,
                byteOffset,
                sampleCount
            )
            // JavaScriptKit copies a typed array's entire backing buffer. Slice this view first so
            // the bridge copies only the bulk result rather than the module's whole linear memory.
            let copiedValues = JSTypedArray<Float64>(unsafelyWrapping: values.slice!().object!)
            copiedValues.copyMemory(to: UnsafeMutableBufferPointer(start: output, count: sampleCount))
        }
    }

    func instantiateBiomeIDBulk(
        module: [UInt8],
        exportName: String,
        memoryExportName: String,
        sampleCount: Int,
        imports: WASMDensityFunctionImports
    ) throws -> WASMBiomeIDBulkInvocation {
        let bridge = makeDensityImports(imports)
        let exports = try instantiateExports(module: module, imports: bridge.object)
        guard
            let exportFunction = exports[exportName].object,
            let memory = exports[memoryExportName].object
        else {
            throw BrowserAppError.message("WASM biome bulk module is missing a required export.")
        }
        retainedImportClosures.append(contentsOf: bridge.closures)
        let exportBox = JSObjectSendableBox(exportFunction)
        let memoryBox = JSObjectSendableBox(memory)

        return { x, y, z, output in
            let byteOffset = Int(exportBox.object(x, y, z).number ?? 0.0)
            guard let buffer = memoryBox.object.buffer.object else { return }
            let values = JSObject.global.Int32Array.object!.new(
                buffer,
                byteOffset,
                sampleCount
            )
            // Slice before bridging so JavaScriptKit only copies the result volume.
            let copiedValues = JSTypedArray<Int32>(unsafelyWrapping: values.slice!().object!)
            copiedValues.copyMemory(to: UnsafeMutableBufferPointer(start: output, count: sampleCount))
        }
    }

    private func makeDensityImports(
        _ imports: WASMDensityFunctionImports
    ) -> (object: JSObject, closures: [JSClosure]) {
        let densityImport = JSClosure { arguments in
            guard arguments.count == 4 else { return 0.0.jsValue }
            return imports.sampleDensity(
                Int32(arguments[0].number ?? 0.0),
                Int32(arguments[1].number ?? 0.0),
                Int32(arguments[2].number ?? 0.0),
                Int32(arguments[3].number ?? 0.0)
            ).jsValue
        }
        let noiseImport = JSClosure { arguments in
            guard arguments.count == 4 else { return 0.0.jsValue }
            return imports.sampleNoise(
                Int32(arguments[0].number ?? 0.0),
                arguments[1].number ?? 0.0,
                arguments[2].number ?? 0.0,
                arguments[3].number ?? 0.0
            ).jsValue
        }

        let importsObject = JSObject()
        let dpreaderImports = JSObject()
        dpreaderImports["sample_density"] = densityImport.jsValue
        dpreaderImports["sample_noise"] = noiseImport.jsValue
        importsObject["dpreader"] = dpreaderImports.jsValue
        return (importsObject, [densityImport, noiseImport])
    }

    func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation {
        let exportFunction = try instantiate(
            module: module,
            exportName: exportName,
            imports: JSObject()
        )
        let exportBox = JSObjectSendableBox(exportFunction)

        return { temperature, humidity, continentalness, erosion, weirdness, depth, previousDistance, previousIndex in
            Int32(exportBox.object(
                temperature,
                humidity,
                continentalness,
                erosion,
                weirdness,
                depth,
                JSBigInt(_slowBridge: previousDistance),
                previousIndex
            ).number ?? -1.0)
        }
    }

    func invalidate() {
        retainedImportClosures.removeAll(keepingCapacity: false)
    }

    private func instantiate(
        module: [UInt8],
        exportName: String,
        imports: JSObject
    ) throws -> JSObject {
        let exports = try instantiateExports(module: module, imports: imports)
        guard let exportFunction = exports[exportName].object else {
            throw BrowserAppError.message("WASM module is missing its \(exportName) export.")
        }
        return exportFunction
    }

    private func instantiateExports(module: [UInt8], imports: JSObject) throws -> JSObject {
        let webAssembly = JSObject.global.WebAssembly.object!
        let moduleBytes = JSTypedArray<UInt8>(module)
        let compiledModule = try webAssembly.Module.object!.throws.new(moduleBytes)
        let instance = try webAssembly.Instance.object!.throws.new(compiledModule, imports)
        guard let exports = instance.exports.object else {
            throw BrowserAppError.message("WASM module did not expose exports.")
        }
        return exports
    }
}

#if canImport(wasi_pthread)
/// Swift Concurrency uses this lock while scheduling work. Spinning avoids blocking the browser's
/// main worker, which cannot use a blocking wait primitive.
@_cdecl("pthread_mutex_lock")
func dappermap_pthread_mutex_lock(_ mutex: UnsafeMutablePointer<pthread_mutex_t>) -> Int32 {
    var result: Int32
    repeat {
        result = pthread_mutex_trylock(mutex)
    } while result == EBUSY
    return result
}
#endif
#endif
