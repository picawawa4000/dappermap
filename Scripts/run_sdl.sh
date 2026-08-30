#!/bin/sh
set -eu

swift build --product dappermap-sdl

binary_directory="$(swift build --show-bin-path)"
runtime_directory="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')"

# A standalone Swift toolchain can be newer than the runtime bundled with macOS/Xcode. Prefer
# its matching runtime, so dyld resolves concurrency symbols from the compiler that built this.
if [ -n "${DYLD_LIBRARY_PATH:-}" ]; then
    export DYLD_LIBRARY_PATH="$runtime_directory:$DYLD_LIBRARY_PATH"
else
    export DYLD_LIBRARY_PATH="$runtime_directory"
fi

exec "$binary_directory/dappermap-sdl"
