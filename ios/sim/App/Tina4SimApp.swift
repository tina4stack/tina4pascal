import SwiftUI

// Native Tina4 iOS-Simulator host: the engine (libtina4iossim.a) renders HTML
// with its native Core Graphics / Core Text canvas straight into a UIView, on
// the Simulator via the patched FPC `iphonesim` target — no physical iPhone.
// See ios/build-sim.sh + docs/fpc-iphonesim.md.
@main
struct Tina4SimApp: App {
    var body: some Scene {
        WindowGroup {
            Tina4ViewRep()
                .ignoresSafeArea()
        }
    }
}
