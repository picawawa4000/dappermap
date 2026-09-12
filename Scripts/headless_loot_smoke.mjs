#!/usr/bin/env node

const debuggingPort = Number(process.env.DAPPERMAP_CDP_PORT ?? "9224");
const appURL = process.env.DAPPERMAP_URL ?? "http://127.0.0.1:8011/index.html";
const seed = process.argv[2];
const centerX = Number(process.argv[3]);
const centerZ = Number(process.argv[4]);

if (!seed || !Number.isFinite(centerX) || !Number.isFinite(centerZ)) {
    throw new Error("usage: headless_loot_smoke.mjs <seed> <center-x> <center-z>");
}

const target = await fetch(`http://127.0.0.1:${debuggingPort}/json/new?${encodeURIComponent(appURL)}`, {
    method: "PUT",
}).then((response) => response.json());
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
});

let nextID = 1;
const pending = new Map();
const diagnostics = [];
let completed = false;
process.on("beforeExit", () => {
    if (!completed) {
        console.log(JSON.stringify({ seed, centerX, centerZ, aborted: true, diagnostics }, null, 2));
    }
});
socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
        const continuation = pending.get(message.id);
        if (continuation) {
            pending.delete(message.id);
            message.error ? continuation.reject(new Error(JSON.stringify(message.error))) : continuation.resolve(message.result);
        }
        return;
    }
    if (message.method === "Runtime.exceptionThrown") {
        diagnostics.push({ type: "exception", value: message.params.exceptionDetails });
        console.error(`browser:exception:${JSON.stringify(message.params.exceptionDetails)}`);
    } else if (message.method === "Runtime.consoleAPICalled") {
        const diagnostic = {
            type: `console.${message.params.type}`,
            value: message.params.args.map((argument) => argument.value ?? argument.description).join(" "),
        };
        diagnostics.push(diagnostic);
        console.error(`browser:${diagnostic.type}:${diagnostic.value}`);
    } else if (message.method === "Log.entryAdded") {
        diagnostics.push({ type: `log.${message.params.entry.level}`, value: message.params.entry.text });
        console.error(`browser:log.${message.params.entry.level}:${message.params.entry.text}`);
    } else if (message.method === "Inspector.targetCrashed" || message.method === "Target.targetCrashed") {
        diagnostics.push({ type: message.method, value: message.params });
    }
});

function command(method, params = {}) {
    const id = nextID++;
    socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
    const result = await command("Runtime.evaluate", {
        expression,
        awaitPromise: true,
        returnByValue: true,
    });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
}

async function waitFor(expression, timeoutMilliseconds = 120_000) {
    const deadline = Date.now() + timeoutMilliseconds;
    while (Date.now() < deadline) {
        const value = await evaluate(expression);
        if (value) return value;
        await new Promise((resolve) => setTimeout(resolve, 250));
    }
    throw new Error(`Timed out waiting for: ${expression}`);
}

await command("Runtime.enable");
await command("Log.enable");
await command("Page.enable");
await command("Inspector.enable");
await waitFor(`document.readyState === "complete"`);
console.error(`dom:${JSON.stringify(await evaluate(`({
    status: Boolean(document.querySelector("#status")),
    biomeGenerationStatus: Boolean(document.querySelector("#biome-generation-status")),
    structureGenerationStatus: Boolean(document.querySelector("#structure-generation-status")),
    currentStatus: document.querySelector("#status")?.innerText ?? ""
})`))}`);
console.error("waiting:datapack");
await waitFor(`document.querySelector("#status")?.innerText.endsWith("datapack ready. Enter a seed and click Render.")`);
console.error("ready:datapack");

await evaluate(`(() => {
    const seedInput = document.querySelector("#seed-input");
    seedInput.value = ${JSON.stringify(seed)};
    document.querySelector("#render-button").click();
    return true;
})()`);

const viewport = await evaluate(`(() => {
    const rect = document.querySelector("#map-viewport").getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
})()`);

// Zoom to 16 blocks per pixel, then pan the requested world coordinate to the center.
await command("Input.dispatchMouseEvent", {
    type: "mouseWheel",
    x: viewport.x,
    y: viewport.y,
    deltaX: 0,
    deltaY: Math.log(16) / 0.0015,
});
await command("Input.dispatchMouseEvent", {
    type: "mousePressed", x: viewport.x, y: viewport.y, button: "left", buttons: 1, clickCount: 1,
});
await command("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: viewport.x - centerX / 16,
    y: viewport.y - centerZ / 16,
    button: "left",
    buttons: 1,
});
await command("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: viewport.x - centerX / 16,
    y: viewport.y - centerZ / 16,
    button: "left",
    buttons: 0,
    clickCount: 1,
});

console.error("waiting:render");
await new Promise((resolve) => setTimeout(resolve, 10_000));
await waitFor(`document.querySelector("#status")?.innerText.startsWith("Rendered seed ")`, 180_000);
console.error(`status:${await evaluate(`document.querySelector("#status")?.innerText`)}`);
console.error("ready:render");
const generationStatuses = await waitFor(`(() => {
    const biomes = document.querySelector("#biome-generation-status")?.innerText ?? "";
    const structures = document.querySelector("#structure-generation-status")?.innerText ?? "";
    return structures.startsWith("Structures: ready") || structures.startsWith("Structures: disabled")
        ? { biomes, structures }
        : null;
})()`, 180_000);
console.error(`ready:generation-statuses:${JSON.stringify(generationStatuses)}`);
await command("Input.dispatchMouseEvent", { type: "mouseMoved", x: viewport.x, y: viewport.y });
console.error("waiting:marker");
const tooltip = await waitFor(`(() => {
    const tooltip = document.querySelector("#map-tooltip");
    return !tooltip.hidden && tooltip.innerText.includes("Structure:") ? tooltip.innerText : "";
})()`, 30_000);
console.error(`ready:marker:${tooltip.replaceAll("\n", " | ")}`);

await command("Input.dispatchMouseEvent", {
    type: "mousePressed", x: viewport.x, y: viewport.y, button: "left", buttons: 1, clickCount: 1,
});
await command("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: viewport.x, y: viewport.y, button: "left", buttons: 0, clickCount: 1,
});

let lootMessage = "";
try {
    console.error("waiting:loot");
    await waitFor(`(() => {
        const message = document.querySelector("#loot-message");
        const finishedMessage = message && !message.hidden && !message.innerText.startsWith("Generating loot");
        return finishedMessage || document.querySelectorAll("#loot-list details").length > 0;
    })()`, 30_000);
    lootMessage = await evaluate(`(() => {
        const message = document.querySelector("#loot-message");
        return message && !message.hidden ? message.innerText : "";
    })()`);
} catch (error) {
    lootMessage = error.message;
}
const lootEntries = await evaluate(`document.querySelectorAll("#loot-list details").length`);
const loot = await evaluate(`Array.from(document.querySelectorAll("#loot-list details")).map((entry) => ({
    title: entry.querySelector("summary")?.innerText ?? "",
    items: Array.from(entry.querySelectorAll("li"), (item) => item.textContent),
}))`);
console.log(JSON.stringify({ seed, centerX, centerZ, tooltip, lootMessage, lootEntries, loot, diagnostics }, null, 2));
completed = true;

await command("Target.closeTarget", { targetId: target.id });
socket.close();
