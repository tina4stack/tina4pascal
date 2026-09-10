import SwiftUI
import WatchKit

// Native Tina4 watch host: the engine (libtina4watch.a) renders HTML on the
// watch and we show its frames. For the physical-watch phone-render mirror see
// StreamModel.swift + examples/watch/watch_server.py (docs/WATCH.md).
@main
struct Tina4WatchApp: App {
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
        ZStack {
            Color.black
            if let img = model.frame {
                // the engine-rendered frame, filling the whole watch 1:1
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("Starting Tina4…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { model.tap() }   // → tina4watch_touch + re-render (wink)
    }
}
