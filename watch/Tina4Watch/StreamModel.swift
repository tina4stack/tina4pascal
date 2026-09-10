import Foundation
import SwiftUI

// The watch is a thin display: it polls engine-rendered frames from the Mac
// render server (examples/watch/watch_server.py) and posts taps back. The Mac
// runs the Tina4 engine and renders the watch HTML at the watch's exact pixel
// resolution, so the frame IS the screen — 1:1, no scaling guesswork. On device
// this transport becomes WatchConnectivity from the paired iPhone; in the
// simulator, localhost reaches the Mac host directly.
final class StreamModel: NSObject, ObservableObject {
    static let shared = StreamModel()

    @Published var frame: UIImage?
    // 127.0.0.1 from the watch simulator reaches the Mac host.
    private let base = "http://127.0.0.1:8723"
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

    func fetch() {
        guard let u = URL(string: base + "/frame") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data = data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async { self?.frame = img }
        }.resume()
    }

    // A tap on the wrist → post to the Mac; its engine re-renders (the wink) and
    // the next polled frame shows it.
    func sendTap(x: CGFloat, y: CGFloat) {
        guard let u = URL(string: base + "/tap?x=\(Int(x))&y=\(Int(y))") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] _, _, _ in self?.fetch() }.resume()
    }
}
