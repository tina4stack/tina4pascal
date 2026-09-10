import SwiftUI
import WatchKit

// Physical-watch mirror app. The real Apple Watch is arm64_32 and can't run the
// native Tina4 engine yet (FPC phase 2), so this thin Swift app displays frames
// rendered on the Mac by the SAME pure-Pascal rasterizer (examples/watch/
// watch_server_raster.py → watchrender → Tina4RasterCanvas). It links no engine
// lib, so it builds for the device. When FPC gains arm64_32 this is retired for
// the native watch/Tina4Watch app. Host/port come from StreamModel (Info.plist
// Tina4ServerHost, :8723).
@main
struct MirrorApp: App {
    @StateObject private var model = StreamModel.shared
    var body: some Scene {
        WindowGroup {
            MirrorView().environmentObject(model)
        }
    }
}

struct MirrorView: View {
    @EnvironmentObject var model: StreamModel
    var body: some View {
        ZStack {
            Color.black
            if let img = model.frame {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "applewatch").font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("Connecting to Tina4…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            WKInterfaceDevice.current().play(.click)
            model.sendTap(x: 0, y: 0)   // → /tap: the Mac re-renders with the accent toggled
        }
    }
}
