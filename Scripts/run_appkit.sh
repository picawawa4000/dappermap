#!/bin/sh
set -eu

swift build --product dappermap

binary_directory="$(swift build --show-bin-path)"
runtime_directory="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')"

# Development Swift toolchains can be newer than the Swift runtime shipped by macOS. Supplying
# the toolchain runtime is harmless for release toolchains and keeps snapshots launchable.
if [ -n "${DYLD_LIBRARY_PATH:-}" ]; then
    export DYLD_LIBRARY_PATH="$runtime_directory:$DYLD_LIBRARY_PATH"
else
    export DYLD_LIBRARY_PATH="$runtime_directory"
fi

exec "$binary_directory/dappermap"
