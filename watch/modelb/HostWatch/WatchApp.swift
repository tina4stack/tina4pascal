import SwiftUI
import WatchKit
import WatchConnectivity

// Model B watch side — a thin display. It receives engine-rendered frames from
// the paired iPhone over WatchConnectivity (no Wi-Fi/LAN), shows them, reports
// its own screen size once so the phone renders 1:1, and sends taps back.
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneLink()
    @Published var frame: UIImage?

    func start() {
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func reportSize() {
        let b = WKInterfaceDevice.current().screenBounds
        let s = WKInterfaceDevice.current().screenScale
        let msg: [String: Any] = ["w": Int(b.width * s), "h": Int(b.height * s)]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        }
    }

    func tap() {
        WKInterfaceDevice.current().play(.click)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["tap": 1], replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: WCSessionDelegate
    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {
        if st == .activated { reportSize() }
    }
    func sessionReachabilityDidChange(_ s: WCSession) { if s.isReachable { reportSize() } }
    // phone → watch: a rendered frame (PNG)
    func session(_ s: WCSession, didReceiveMessageData data: Data) {
        if let img = UIImage(data: data) {
            DispatchQueue.main.async { self.frame = img }
        }
    }
}

@main
struct TinaHostWatchApp: App {
    @StateObject private var link = PhoneLink.shared
    var body: some Scene {
        WindowGroup {
            WatchDisplay().environmentObject(link).onAppear { link.start() }
        }
    }
}

struct WatchDisplay: View {
    @EnvironmentObject var link: PhoneLink
    var body: some View {
        ZStack {
            Color.black
            if let img = link.frame {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "iphone.gen3").font(.system(size: 24, weight: .semibold)).foregroundStyle(.blue)
                    Text("Waiting for phone…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { link.tap() }
    }
}
