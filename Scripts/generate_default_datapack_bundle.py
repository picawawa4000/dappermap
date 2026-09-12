#!/usr/bin/env python3

import argparse
import base64
import gzip
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VANILLA_WORLDGEN_VERSIONS = [
    "1.21", "1.21.2", "1.21.4", "1.21.5", "1.21.6", "1.21.9", "1.21.11", "26.1", "26.2", "26.3-pre-1",
]

# Client jars contain the built-in data tree but not its root pack metadata. DPReader must receive
# the exact data-pack format so it can select the matching versioned schema while decoding it.
PACK_METADATA = {
    "1.21": {"pack_format": 48},
    "1.21.2": {"pack_format": 57},
    "1.21.4": {"pack_format": 61},
    "1.21.5": {"pack_format": 71},
    "1.21.6": {"pack_format": 80},
    "1.21.9": {"min_format": 88, "max_format": 88},
    "1.21.11": {"min_format": [94, 1], "max_format": [94, 1]},
    "26.1": {"min_format": [101, 1], "max_format": [101, 1]},
    "26.2": {"min_format": [107, 1], "max_format": [107, 1]},
    "26.3-pre-1": {"min_format": [119, 0], "max_format": [119, 0]},
}

INCLUDE_GLOBS = [
    "data/minecraft/worldgen/biome/*.json",
    "data/minecraft/worldgen/density_function/**/*.json",
    "data/minecraft/worldgen/noise/*.json",
    "data/minecraft/worldgen/noise_settings/**/*.json",
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


def output_path_for(version: str) -> Path:
    return ROOT / "Web" / f"vanilla-{version}-datapack.bundle.json.gz"


def write_bundle(version: str) -> None:
    source_root = ROOT / "Data" / version
    output = output_path_for(version)
    if not source_root.is_dir():
        raise FileNotFoundError(f"Missing {source_root}. Extract it with DPReader's Scripts/extract_vanilla_datapack.py first.")
    files = [{"path": "pack.mcmeta", "contents": json.dumps({"pack": {**PACK_METADATA[version], "description": f"DapperMap vanilla {version}"}}, separators=(",", ":"))}]
    seen = set()

    for pattern in INCLUDE_GLOBS:
        for path in sorted(source_root.glob(pattern)):
            relative = path.relative_to(source_root).as_posix()
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

    output.parent.mkdir(parents=True, exist_ok=True)
    bundle = json.dumps({"id": version, "files": files}, separators=(",", ":")).encode("utf-8")
    # Use a fixed timestamp so repeated builds remain reproducible.
    output.write_bytes(gzip.compress(bundle, mtime=0))
    print(f"Wrote {len(files)} files to {output} ({len(bundle)} bytes uncompressed)")


def main() -> None:
    parser = argparse.ArgumentParser(description="Bundle vanilla datapacks for DapperMap's browser frontend.")
    parser.add_argument("--version", choices=VANILLA_WORLDGEN_VERSIONS, action="append")
    args = parser.parse_args()
    for version in args.version or VANILLA_WORLDGEN_VERSIONS:
        write_bundle(version)


if __name__ == "__main__":
    main()
