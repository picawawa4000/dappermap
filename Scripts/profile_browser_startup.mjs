import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { WASI } from "node:wasi";

import { SwiftRuntime } from "../.build/checkouts/JavaScriptKit/Plugins/PackageToJS/Templates/runtime.mjs";

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wasmPath = path.join(rootDir, ".build/wasm32-unknown-wasip1/release/dappermap.wasm");

const timeline = [];
const startTime = performance.now();
const viewportSize = Number(process.env.DAPPERMAP_PROFILE_VIEWPORT_SIZE ?? "1536");
const blocksPerPixel = Number(process.env.DAPPERMAP_PROFILE_BLOCKS_PER_PIXEL ?? "1");
const centerX = Number(process.env.DAPPERMAP_PROFILE_CENTER_X ?? "0");
const centerZ = Number(process.env.DAPPERMAP_PROFILE_CENTER_Z ?? "0");
const panBeforeRender = Number(process.env.DAPPERMAP_PROFILE_PAN_BEFORE_RENDER ?? "0");

function nowMs() {
    return performance.now() - startTime;
}

function record(label, extra = {}) {
    timeline.push({ t: nowMs(), label, ...extra });
}

class MockElement {
    constructor(id) {
        this.id = id;
        this.disabled = false;
        this.value = "";
        this.className = "";
        this.listeners = new Map();
        this._innerText = "";
        this.style = {};
        this.classList = { add() {}, remove() {} };
        this.children = [];
        this.hidden = false;
        this.files = [];
    }

    addEventListener(type, listener) {
        let handlers = this.listeners.get(type);
        if (!handlers) {
            handlers = [];
            this.listeners.set(type, handlers);
        }
        handlers.push(listener);
    }

    dispatch(type, event = {}) {
        for (const listener of this.listeners.get(type) ?? []) {
            listener({ preventDefault() {}, ...event });
        }
    }

    appendChild(child) {
        this.children.push(child);
        return child;
    }

    removeChild(child) {
        this.children = this.children.filter((item) => item !== child);
        return child;
    }

    querySelector() {
        return new MockElement("input");
    }

    click() {
        this.dispatch("click");
    }

    getBoundingClientRect() {
        return { left: 0, top: 0, width: viewportSize, height: viewportSize };
    }

    get innerText() {
        return this._innerText;
    }

    set innerText(value) {
        this._innerText = value;
        if (this.id === "status") {
            record(`status:${value}`);
            if (value.endsWith("datapack ready. Enter a seed and click Render.")) {
                readyResolve?.();
            }
            if (value.startsWith("Rendered seed ") || value.startsWith("Render failed:")) {
                renderResolve?.(value);
            }
        }
    }
}

class MockCanvas extends MockElement {
    constructor(id) {
        super(id);
        this.width = 0;
        this.height = 0;
        this.context2d = {
            fillStyle: "",
            imageSmoothingEnabled: false,
            clearRect() {},
            fillRect() {},
            drawImage() {},
            putImageData() {},
            beginPath() {},
            moveTo() {},
            lineTo() {},
            stroke() {},
            fillText() {},
        };
    }

    getContext(kind) {
        if (kind !== "2d") {
            throw new Error(`Unsupported context kind: ${kind}`);
        }
        return this.context2d;
    }
}

const elementIDs = [
    "map-viewport",
    "page-select",
    "minecraft-version-input",
    "seed-input",
    "dimension-input",
    "y-input",
    "render-button",
    "status",
    "biome-generation-status",
    "structure-generation-status",
    "biome-reset-button",
    "biome-import-button",
    "biome-export-button",
    "biome-export-cubiomes-button",
    "biome-import-input",
    "biome-summary",
    "biome-empty",
    "biome-list",
    "structure-reset-button",
    "structure-summary",
    "structure-empty",
    "structure-list",
    "loot-info",
    "loot-filter-input",
    "loot-message",
    "loot-list",
    "debug-last-tile",
    "debug-density-compilation",
    "debug-generation-time",
    "debug-render-time",
    "debug-pending-tiles",
    "debug-cached-tiles",
    "debug-structure-time",
    "debug-structure-sampling",
    "debug-structure-validation",
    "debug-structure-candidates",
    "debug-structure-accepted",
    "debug-structure-rejected",
    "debug-structure-cache-hits",
    "debug-structure-types",
    "map-tooltip",
    "map-canvas",
    "map-overlay",
];
const elements = new Map(elementIDs.map((id) => [
    id,
    id === "map-canvas" || id === "map-overlay" ? new MockCanvas(id) : new MockElement(id),
]));
elements.get("seed-input").value = "0";

globalThis.ImageData = class ImageData {
    constructor(data, width, height) {
        this.data = data;
        this.width = width;
        this.height = height;
    }
};

const document = {
    getElementById(id) {
        const element = elements.get(id);
        if (!element) {
            throw new Error(`Unknown DOM id: ${id}`);
        }
        return element;
    },
    createElement(tagName) {
        return tagName === "canvas" ? new MockCanvas(tagName) : new MockElement(tagName);
    },
    body: new MockElement("body"),
};

globalThis.document = document;
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.__dappermapProfile = 1;
globalThis.__dappermapProfileBlocksPerPixel = blocksPerPixel;
globalThis.__dappermapProfileCenterX = centerX;
globalThis.__dappermapProfileCenterZ = centerZ;
globalThis.addEventListener = () => {};

globalThis.fetch = async function fetchLocal(resource) {
    const spec = typeof resource === "string" ? resource : String(resource);
    const resolvedPath = path.resolve(rootDir, spec);
    record("fetch:start", { spec });
    const bytes = await fs.readFile(resolvedPath);
    const text = spec.endsWith("-datapack.bundle.json.gz")
        ? gunzipSync(bytes).toString("utf8")
        : bytes.toString("utf8");
    record("fetch:end", { spec, bytes: Buffer.byteLength(text, "utf8") });
    return {
        async text() {
            record("response.text");
            return text;
        },
    };
};

const wasi = new WASI({
    version: "preview1",
    args: [wasmPath],
    env: {},
    preopens: {
        "/": rootDir,
    },
});

function createBridgeImports() {
    const unexpected = () => {
        throw new Error("Unexpected call to BridgeJS function");
    };
    return {
        bjs: {
            swift_js_return_string: unexpected,
            swift_js_init_memory: unexpected,
            swift_js_make_js_string: unexpected,
            swift_js_init_memory_with_result: unexpected,
            swift_js_throw: unexpected,
            swift_js_retain: unexpected,
            swift_js_release: unexpected,
            swift_js_push_tag: unexpected,
            swift_js_push_int: unexpected,
            swift_js_push_f32: unexpected,
            swift_js_push_f64: unexpected,
            swift_js_push_string: unexpected,
            swift_js_pop_param_int32: unexpected,
            swift_js_pop_param_f32: unexpected,
            swift_js_pop_param_f64: unexpected,
            swift_js_return_optional_bool: unexpected,
            swift_js_return_optional_int: unexpected,
            swift_js_return_optional_string: unexpected,
            swift_js_return_optional_double: unexpected,
            swift_js_return_optional_float: unexpected,
            swift_js_return_optional_heap_object: unexpected,
            swift_js_return_optional_object: unexpected,
            swift_js_get_optional_int_presence: unexpected,
            swift_js_get_optional_int_value: unexpected,
            swift_js_get_optional_string: unexpected,
            swift_js_get_optional_float_presence: unexpected,
            swift_js_get_optional_float_value: unexpected,
            swift_js_get_optional_double_presence: unexpected,
            swift_js_get_optional_double_value: unexpected,
            swift_js_get_optional_heap_object_pointer: unexpected,
        },
    };
}

let readyResolve;
const ready = new Promise((resolve) => {
    readyResolve = resolve;
});
let renderResolve;

const swift = new SwiftRuntime();
const wasmBytes = await fs.readFile(wasmPath);
record("wasm:read", { bytes: wasmBytes.byteLength });
const module = await WebAssembly.compile(wasmBytes);
record("wasm:compiled");

const imports = {
    javascript_kit: swift.wasmImports,
    wasi_snapshot_preview1: wasi.wasiImport,
    ...createBridgeImports(),
};

const instance = await WebAssembly.instantiate(module, imports);
record("wasm:instantiated");

swift.setInstance(instance);
wasi.initialize(instance);
record("wasi:initialized");

swift.main();
record("swift.main:returned");

const timeout = new Promise((_, reject) => {
    setTimeout(() => reject(new Error("Timed out waiting for the app")), 600000);
});

function waitForRender() {
    return new Promise((resolve) => {
        renderResolve = resolve;
    });
}

function panByPixels(dx, dy) {
    const viewport = elements.get("map-viewport");
    const center = viewportSize / 2;
    viewport.dispatch("pointerdown", { pointerId: 1, clientX: center, clientY: center });
    viewport.dispatch("pointermove", { pointerId: 1, clientX: center - dx, clientY: center - dy });
    viewport.dispatch("pointerup", { pointerId: 1, clientX: center - dx, clientY: center - dy });
}

function zoomToRequestedScale() {
    if (blocksPerPixel === 1) return;
    elements.get("map-viewport").dispatch("wheel", {
        clientX: viewportSize / 2,
        clientY: viewportSize / 2,
        deltaY: Math.log(blocksPerPixel) / 0.0015,
    });
}

async function render(label, action) {
    const rendered = waitForRender();
    record(`${label}:start`);
    action();
    const status = await Promise.race([rendered, timeout]);
    record(`${label}:end`, { status });
}

try {
    await Promise.race([ready, timeout]);
    record("ready");
    await render(`region-a-bpp-${blocksPerPixel}`, () => {
        elements.get("render-button").dispatch("click");
        zoomToRequestedScale();
        if (panBeforeRender) {
            panByPixels(viewportSize * 2, 0);
        }
    });
} catch (error) {
    record("timeout", { message: error.message });
    console.log(JSON.stringify(timeline, null, 2));
    throw error;
}

console.log(JSON.stringify(timeline, null, 2));
