import SwiftUI

// Native Tina4 iOS-Simulator host: the engine (libtina4iossim.a) renders HTML
// and we show its frames. Runs on the Simulator via the patched FPC `iphonesim`
// target — no physical iPhone needed. See ios/build-sim.sh + docs/fpc-iphonesim.md.
@main
struct Tina4SimApp: App {
    @StateObject private var model = EngineModel.shared
    var body: some Scene {
        WindowGroup {
            EngineView().environmentObject(model)
                .onAppear { model.start() }
        }
    }
}

struct EngineView: View {
    @EnvironmentObject var model: EngineModel

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black
                if let img = model.frame {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text("Starting Tina4…")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { g in
                    model.tap(at: g.location)   // → tina4sim_touch + re-render
                }
            )
        }
    }
}
