#!/usr/bin/env python3

import base64
import gzip
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "Data" / "1.21.11"
OUTPUT = ROOT / "Web" / "default-datapack.bundle.json.gz"
UNCOMPRESSED_OUTPUT = ROOT / "Web" / "default-datapack.bundle.json"

INCLUDE_GLOBS = [
    "data/minecraft/worldgen/biome/*.json",
    "data/minecraft/worldgen/density_function/**/*.json",
    "data/minecraft/worldgen/noise/*.json",
    "data/minecraft/worldgen/noise_settings/overworld.json",
    "data/minecraft/worldgen/structure/*.json",
    "data/minecraft/worldgen/structure_set/*.json",
    "data/minecraft/worldgen/template_pool/**/*.json",
    "data/minecraft/worldgen/processor_list/**/*.json",
    "data/minecraft/tags/worldgen/biome/**/*.json",
    "data/minecraft/enchantment/**/*.json",
    "data/minecraft/tags/enchantment/**/*.json",
    "data/minecraft/tags/item/**/*.json",
    "data/minecraft/loot_table/**/*.json",
    "data/minecraft/structure/**/*.nbt",
]


def main() -> None:
    files = []
    seen = set()

    for pattern in INCLUDE_GLOBS:
        for path in sorted(SOURCE_ROOT.glob(pattern)):
            relative = path.relative_to(SOURCE_ROOT).as_posix()
            if relative in seen:
                continue
            seen.add(relative)
            if path.suffix == ".nbt":
                # DPReader's WASI build cannot inflate gzip-compressed templates. Minecraft's
                # source files are gzip streams despite their .nbt extension, so bundle their
                # uncompressed NBT payloads for browser-side loading.
                contents = gzip.decompress(path.read_bytes())
                files.append(
                    {
                        "path": relative,
                        "base64Contents": base64.b64encode(contents).decode("ascii"),
                    }
                )
            else:
                contents = path.read_text(encoding="utf-8")
                if path.suffix == ".json":
                    contents = json.dumps(json.loads(contents), separators=(",", ":"))
                files.append(
                    {
                        "path": relative,
                        "contents": contents,
                    }
                )

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    bundle = json.dumps({"files": files}, separators=(",", ":")).encode("utf-8")
    # Use a fixed timestamp so repeated builds remain reproducible.
    OUTPUT.write_bytes(gzip.compress(bundle, mtime=0))
    UNCOMPRESSED_OUTPUT.unlink(missing_ok=True)
    print(f"Wrote {len(files)} files to {OUTPUT} ({len(bundle)} bytes uncompressed)")


if __name__ == "__main__":
    main()
