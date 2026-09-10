import SwiftUI

// The iPhone host: runs the Tina4 engine and streams the watch face over
// WatchConnectivity. The phone UI is just a monitor — the real screen is the
// watch. Call PASCALMAIN() etc. lives in RenderModel.
@main
struct TinaHostApp: App {
    @StateObject private var model = RenderModel.shared
    var body: some Scene {
        WindowGroup {
            HostView().environmentObject(model).onAppear { model.start() }
        }
    }
}

struct HostView: View {
    @EnvironmentObject var model: RenderModel
    var body: some View {
        VStack(spacing: 18) {
            Text("Tina4 · Watch Host").font(.title2.bold())
            Text("The engine runs here; the watch shows these frames.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let img = model.preview {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(width: 180).clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.secondary.opacity(0.3)))
            } else {
                RoundedRectangle(cornerRadius: 24).fill(.black).frame(width: 180, height: 220)
                    .overlay(Text("rendering…").foregroundStyle(.secondary))
            }
            Text(model.status).font(.callout).foregroundStyle(.blue)
        }
        .padding()
    }
}
