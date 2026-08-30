import DapperMapEngine

#if canImport(AppKit)
import DapperMapAppKit
#endif
@main
enum DapperMapMain {
    @MainActor
    static func main() {
#if os(WASI)
        startBrowserApp()
#elseif canImport(AppKit)
        launchCoreGraphicsApp()
#else
        print("The AppKit frontend is unavailable on this platform. Use dappermap-sdl.")
#endif
    }
}
