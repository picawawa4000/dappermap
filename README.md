# DapperMap

DapperMap is a seed viewer for Minecraft. It supports biomes, structure positions, and structure loot. Currently, it can be built for execution via WASM, Apple's AppKit, or SDL.

It is based on DPReader, which can be found at <https://github.com/picawawa4000/dpreader-swift>. Generation errors should be reported there, while map errors should be reported here.

All frontends offer the first release for every distinct vanilla worldgen state from 1.21 through
26.3; releases without worldgen changes use the preceding
entry. 1.21.11 remains the default. The
AppKit and SDL version selectors are in the Map panel. SDL has a left sidebar with mouse controls
for rendering, versions, coordinates, zoom, and settings. Click a text field to edit it; Tab moves
between fields, and Ctrl/Cmd-A/C/X/V selects, copies, cuts, and pastes text. Scroll over the sidebar
to browse panels and results, or over the map to zoom. The Loot Search tab supports item queries,
progress, cancellation, copying results, and jumping to matching containers. Native versions load
`Data/<version>`, extracted with DPReader's `Scripts/extract_vanilla_datapack.py`, and pass the
corresponding pack format to DPReader.

## Build Instructions

Install Swift 6.3.3 using whatever method is preferred on your system.

Build scripts are provided in the `Scripts` directory.

* `Scripts/build_web.sh` will build the web-based target; `Scripts/serve.py` will then open a local server for it on the specified port (or 8000 by default). (The script is required because it sends CORS headers.)
* `Scripts/run_appkit.sh` will build and run the AppKit-based target.
* `Scripts/run_sdl.sh` will build and run the SDL-based target.

The Debug tab's Advanced Settings controls native generation/search thread counts and LLVM density compilation. Native loot searches use dedicated workers, leaving map-generation workers responsive.

## SDL validation

`swift test --filter SDL` exercises text editing, mouse hit regions, scrolling, markers,
and asynchronous result handling with SDL's software renderer (no window required).
To also run the real loot-search integration check, set
`SDL_TEST_DATAPACK="$PWD/Data/1.21.11"`. Set `SDL_TEST_SCREENSHOTS` to an existing directory
to save BMP snapshots of the tested screens.

## Disclaimer

This project is not affiliated with Minecraft, nor is it authorised by Microsoft or Mojang AB.
