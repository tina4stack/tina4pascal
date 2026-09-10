import SwiftUI

@main
struct Tina4WatchApp: App {
    @StateObject private var model = StreamModel.shared
    var body: some Scene {
        WindowGroup {
            StreamView().environmentObject(model)
        }
    }
}

struct StreamView: View {
    @EnvironmentObject var model: StreamModel

    var body: some View {
        ZStack {
            Color.black
            if let img = model.frame {
                // the engine-rendered frame, filling the whole watch 1:1
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("Connecting to Tina4…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .ignoresSafeArea()
        // any tap on the wrist → the Mac engine winks and pushes the next frame
        .contentShape(Rectangle())
        .onTapGesture { model.sendTap(x: 0, y: 0) }
    }
}
