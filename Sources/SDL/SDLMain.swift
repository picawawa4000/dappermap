import DapperMapCore
import DapperMapEngine
import DPReader
import Foundation
import SDL2

@main
struct DapperMapSDLMain {
    @MainActor
    static func main() {
        guard SDL_Init(UInt32(SDL_INIT_VIDEO)) == 0 else {
            fputs("SDL initialization failed: \(String(cString: SDL_GetError()))\n", stderr)
            return
        }
        defer { SDL_Quit() }

        let app = SDLMapApplication()
        app.run()
    }
}

