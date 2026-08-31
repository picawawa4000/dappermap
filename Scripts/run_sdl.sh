#!/bin/sh
set -eu

# DPReader's native JIT is substantially faster than scalar sampling. Enable it automatically
# when a supported Homebrew LLVM is present; callers can still set DPREADER_ENABLE_LLVM=0.
llvm_prefix=""
for candidate in /opt/homebrew/opt/llvm /usr/local/opt/llvm; do
    if [ -f "$candidate/lib/libLLVM-C.dylib" ]; then
        llvm_prefix="$candidate"
        if [ -z "${DPREADER_ENABLE_LLVM+x}" ]; then
            export DPREADER_ENABLE_LLVM=1
        fi
        break
    fi
done
if [ "${DPREADER_ENABLE_LLVM:-0}" = "1" ] && [ -n "$llvm_prefix" ]; then
    export CPATH="$llvm_prefix/include${CPATH:+:$CPATH}"
fi

swift build -c release --product dappermap-sdl

binary_directory="$(swift build -c release --show-bin-path)"
runtime_directory="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')"

# A standalone Swift toolchain can be newer than the runtime bundled with macOS/Xcode. Prefer
# its matching runtime, so dyld resolves concurrency symbols from the compiler that built this.
if [ -n "${DYLD_LIBRARY_PATH:-}" ]; then
    export DYLD_LIBRARY_PATH="$runtime_directory:$DYLD_LIBRARY_PATH"
else
    export DYLD_LIBRARY_PATH="$runtime_directory"
fi

exec "$binary_directory/dappermap-sdl"
