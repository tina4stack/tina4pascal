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
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = model.frame {
                    // the engine-rendered frame from the phone, filling the wrist
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                } else {
                    // before the first frame arrives
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.blue)
                        Text(model.reachable ? "Waiting for phone…" : "Open Tina4 on iPhone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            // a tap on the wrist is forwarded to the phone's engine (in points)
            .contentShape(Rectangle())
            .onTapGesture { loc in model.sendTap(x: loc.x, y: loc.y) }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
