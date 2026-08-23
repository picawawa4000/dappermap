#!/bin/sh
set -eu

sdk_id="${SWIFT_SDK_ID:-6.3-SNAPSHOT-2026-08-14-a-wasm32-unknown-wasip1-threads}"

# Keep the browser datapack in step with the source data. Structure loot tables are
# consumed at runtime and are not part of SwiftPM's WASM plugin output.
python3 Scripts/generate_default_datapack_bundle.py

swift package \
  --swift-sdk "$sdk_id" \
  -c release \
  plugin --allow-writing-to-package-directory \
  js --product dappermap --use-cdn
