import Foundation
import SwiftUI
import WatchKit

// The watch is a thin display: it polls engine-rendered frames from the Mac
// render server (examples/watch/watch_server.py) and posts taps back. The Mac
// runs the Tina4 engine and renders the watch HTML at the watch's exact pixel
// resolution, so the frame IS the screen — 1:1, no scaling guesswork. On device
// this transport becomes WatchConnectivity from the paired iPhone; in the
// simulator, localhost reaches the Mac host directly.
final class StreamModel: NSObject, ObservableObject {
    static let shared = StreamModel()

    @Published var frame: UIImage?
    // The Mac render server. In the watchOS Simulator, 127.0.0.1 reaches the Mac
    // host directly; a PHYSICAL watch can't — set Tina4ServerHost in Info.plist
    // (project.yml) to the Mac's LAN IP (e.g. 192.168.0.x, same WiFi).
    private lazy var base: String = {
        let host = (Bundle.main.object(forInfoDictionaryKey: "Tina4ServerHost") as? String) ?? "127.0.0.1"
        return "http://\(host):8723"
    }()
    private var timer: Timer?

    override init() {
        super.init()
        // bundled first frame until the stream connects
        if let url = Bundle.main.url(forResource: "demo", withExtension: "png"),
           let d = try? Data(contentsOf: url) { frame = UIImage(data: d) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        fetch()
    }

    // the watch's own screen size in points — the server renders to match, so
    // the frame fits any watch (Series 7 vs Ultra) with no cropping
    private var size: String {
        let b = WKInterfaceDevice.current().screenBounds
        return "w=\(Int(b.width))&h=\(Int(b.height))"
    }

    func fetch() {
        guard let u = URL(string: base + "/frame?" + size) else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async { self?.frame = img }
        }.resume()
    }

    // A tap on the wrist → post to the Mac; its engine re-renders (the wink) and
    // the next polled frame shows it.
    func sendTap(x: CGFloat, y: CGFloat) {
        guard let u = URL(string: base + "/tap?" + size) else { return }
        URLSession.shared.dataTask(with: u) { [weak self] _, _, _ in self?.fetch() }.resume()
    }
}
