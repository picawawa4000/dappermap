# DapperMap

DapperMap is a seed viewer for Minecraft. It supports biomes, structure positions, and structure loot. Currently, it can be built for execution via WASM, Apple's AppKit, or SDL.

It is based on DPReader, which can be found at <https://github.com/picawawa4000/dpreader-swift>. Generation errors should be reported there, while map errors should be reported here.

Currently, the app only supports 1.21.11, and that version is selected by default. There are plans to add support for other versions and datapack-based generation (as that's DPReader's whole bit), but since this app is in alpha anyways, my focus is on implementing all the features that I want right now.

## Build Instructions

Install Swift 6.3.3 using whatever method is preferred on your system.

Build scripts are provided in the `Scripts` directory.

* `Scripts/build_web.sh` will build the web-based target; `Scripts/serve.py` will then open a local server for it on the specified port (or 8000 by default). (The script is required because it sends CORS headers.)
* `Scripts/run_appkit.sh` will build and run the AppKit-based target.
* `Scripts/run_sdl.sh` will build and run the SDL-based target.

For the two native targets, you can specify `DAPPERMAP_ENABLE_LLVM=1`, which will enable compiling density functions down to bytecode via LLVM. This is currently disabled by default as the functions take a while to compile and the benefits are (relatively) marginal.

## Disclaimer

This project is not affiliated with Minecraft, nor is it authorised by Microsoft or Mojang AB.
