import SwiftUI
import WatchConnectivity

// Model B — the ENGINE runs on the iPhone. libtina4watch-ios.a renders the watch
// face (HTML → RGBA via the pure-Pascal Tina4RasterCanvas), and we push the frame
// to the watch over WatchConnectivity (Bluetooth/phone link — no Wi-Fi, no Mac,
// no LAN). The watch is a thin display; taps flow back over the same link. This
// is the shippable, network-independent Tina4-on-Apple-Watch architecture until
// FPC gains arm64_32 (then the engine moves onto the watch itself).
final class RenderModel: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = RenderModel()

    @Published var preview: UIImage?          // what the phone is sending
    @Published var status = "starting…"
    @Published var frames = 0

    private var pink = false
    private var watchW = 396, watchH = 484    // watch pixels; the watch reports its real size
    private var timer: Timer?
    private var started = false

    static let logoWebP = "data:image/webp;base64,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"

    func start() {
        guard !started else { return }
        started = true
        PASCALMAIN()
        tina4watch_init(Int32(watchW), Int32(watchH))
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        let html = clock(w: watchW, h: watchH, pink: pink)
        html.withCString { tina4watch_set_html($0) }
        guard let buf = tina4watch_render(Int32(watchW), Int32(watchH), 1.0),
              let img = Self.image(from: buf, w: watchW, h: watchH) else { return }
        DispatchQueue.main.async { self.preview = img }
        // push to the watch when reachable
        if WCSession.default.activationState == .activated, WCSession.default.isReachable,
           let png = img.pngData() {
            WCSession.default.sendMessageData(png, replyHandler: nil, errorHandler: nil)
            DispatchQueue.main.async { self.frames += 1; self.status = "streaming to watch (\(self.frames))" }
        } else {
            DispatchQueue.main.async {
                self.status = WCSession.default.isPaired ? "watch not reachable (open the app on it)" : "no watch paired"
            }
        }
    }

    // MARK: WCSessionDelegate
    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.status = st == .activated ? "watch link active" : "activating…" }
    }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
    func sessionReachabilityDidChange(_ s: WCSession) { tick() }

    // watch → phone: its screen size (once) and taps
    func session(_ s: WCSession, didReceiveMessage m: [String: Any]) {
        if let w = m["w"] as? Int, let h = m["h"] as? Int, w > 0, h > 0, (w != watchW || h != watchH) {
            watchW = w; watchH = h; tina4watch_init(Int32(w), Int32(h))
        }
        if m["tap"] != nil {
            pink.toggle()
            _ = tina4watch_touch(0, Float(watchW) / 2, Float(watchH) / 2)
            _ = tina4watch_touch(1, Float(watchW) / 2, Float(watchH) / 2)
        }
        DispatchQueue.main.async { self.tick() }
    }

    // MARK: engine buffer → UIImage (same $AARRGGBB LE = BGRA, opaque)
    static func image(from buf: UnsafeMutableRawPointer, w: Int, h: Int) -> UIImage? {
        let data = Data(bytes: buf, count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // the same clock face as the native watch app (WebP logo + 7-seg/stroke text)
    func clock(w: Int, h: Int, pink: Bool) -> String {
        let now = Date(); let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .month, .day, .weekday], from: now)
        func p2(_ v: Int) -> String { String(format: "%02d", v) }
        let hhmm = "\(p2(c.hour ?? 0)):\(p2(c.minute ?? 0))"; let ss = p2(c.second ?? 0)
        let days = ["", "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let date = "\(days[c.weekday ?? 1]) \(p2(c.month ?? 0))-\(p2(c.day ?? 0))"
        let accent = pink ? "#ff5aa0" : "#ffd23c"
        let logoSz = Int(Double(h) * 0.17), logoLeft = (w - Int(Double(h) * 0.17)) / 2, logoTop = Int(Double(h) * 0.03)
        let bigFS = Int(Double(h) * 0.24), bigTop = Int(Double(h) * 0.35)
        let secFS = Int(Double(h) * 0.12), secTop = bigTop + bigFS + Int(Double(h) * 0.03)
        let topFS = Int(Double(h) * 0.085), topTop = Int(Double(h) * 0.22)
        let brandFS = Int(Double(h) * 0.09), brandTop = h - Int(Double(h) * 0.05) - Int(Double(h) * 0.09)
        func line(_ t: String, _ top: Int, _ fs: Int, _ col: String) -> String {
            "<div style=\"position:absolute;left:0px;top:\(top)px;width:\(w)px;text-align:center;font-size:\(fs)px;font-weight:bold;color:\(col)\">\(t)</div>"
        }
        let logo = "<img src=\"\(Self.logoWebP)\" style=\"position:absolute;left:\(logoLeft)px;top:\(logoTop)px;width:\(logoSz)px;height:\(logoSz)px\">"
        return """
        <body style="margin:0;width:\(w)px;height:\(h)px;background:#0e0f1f">
          \(logo)\(line(date, topTop, topFS, "#9698b4"))\(line(hhmm, bigTop, bigFS, accent))\(line(ss, secTop, secFS, "#7d8cff"))\(line("tina watch", brandTop, brandFS, "#2b41e6"))
        </body>
        """
    }
}
