import Foundation
import SwiftUI
import WatchKit

// The watch runs the Tina4 engine ITSELF: libtina4watch.a renders HTML to an
// RGBA buffer with the pure-Pascal software rasterizer (Tina4RasterCanvas), and
// we wrap that buffer in a UIImage for SwiftUI. No phone, no network — the same
// engine, HTML and events as every other Tina4 surface, now on the wrist.
//
// This face is a live clock: the engine draws the time with the raster path's
// 7-segment numeric font (Tina4RasterCanvas.DrawText). It re-renders every
// second, so you can watch the seconds tick — each frame is the Pascal engine
// laying out and rasterizing HTML on the watch.
final class EngineModel: ObservableObject {
    static let shared = EngineModel()

    @Published var frame: UIImage?
    private var started = false
    private var timer: Timer?
    private var accentPink = false   // tap toggles the accent

    private var points: CGSize { WKInterfaceDevice.current().screenBounds.size }
    private var scale: CGFloat { WKInterfaceDevice.current().screenScale }

    func start() {
        guard !started else { return }
        started = true
        PASCALMAIN()                                   // bring up the FPC runtime once
        let w = Int(points.width * scale), h = Int(points.height * scale)
        tina4watch_init(Int32(w), Int32(h))
        render()
        // tick every second so the seconds advance
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    // A tap → the engine event path + a visible response (swap the accent colour).
    func tap() {
        WKInterfaceDevice.current().play(.click)
        let mid = Float(points.width * scale) / 2
        _ = tina4watch_touch(0, mid, mid)
        _ = tina4watch_touch(1, mid, mid)
        accentPink.toggle()
        render()
    }

    func render() {
        let w = Int(points.width * scale), h = Int(points.height * scale)
        let html = clock(w: w, h: h, accentPink: accentPink)
        html.withCString { tina4watch_set_html($0) }
        guard let buf = tina4watch_render(Int32(w), Int32(h), 1.0) else { return }
        if let img = Self.image(from: buf, w: w, h: h, scale: scale) { frame = img }
    }

    // Wrap the engine's $AARRGGBB (little-endian → BGRA) top-left-origin buffer as
    // an opaque CGImage — the watch UI fills the screen with a solid background.
    private static func image(from buf: UnsafeMutableRawPointer, w: Int, h: Int, scale: CGFloat) -> UIImage? {
        let data = Data(bytes: buf, count: w * h * 4)   // copy: the engine reuses its buffer
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    // A numeric clock face — HH:MM big, seconds and the date (MM-DD) below. All
    // digits + ':' + '-', which the engine's 7-segment raster font draws.
    private func clock(w: Int, h: Int, accentPink: Bool) -> String {
        let now = Date()
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .month, .day, .weekday], from: now)
        func p2(_ v: Int) -> String { String(format: "%02d", v) }
        let hhmm = "\(p2(c.hour ?? 0)):\(p2(c.minute ?? 0))"
        let ss = p2(c.second ?? 0)
        // weekday + date, all rendered by the engine's raster letter/number font
        let days = ["", "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let dow = days[(c.weekday ?? 1)]
        let date = "\(dow) \(p2(c.month ?? 0))-\(p2(c.day ?? 0))"
        let accent = accentPink ? "#ff5aa0" : "#ffd23c"

        let bigFS = Int(Double(h) * 0.26)
        let bigTop = Int(Double(h) * 0.30)
        let secFS = Int(Double(h) * 0.13)
        let secTop = bigTop + bigFS + Int(Double(h) * 0.03)
        let topFS = Int(Double(h) * 0.10)
        let topTop = Int(Double(h) * 0.07)
        let brandFS = Int(Double(h) * 0.09)
        let brandTop = h - Int(Double(h) * 0.05) - brandFS

        func line(_ txt: String, _ top: Int, _ fs: Int, _ col: String) -> String {
            "<div style=\"position:absolute;left:0px;top:\(top)px;width:\(w)px;text-align:center;"
            + "font-size:\(fs)px;font-weight:bold;color:\(col)\">\(txt)</div>"
        }
        return """
        <body style="margin:0;width:\(w)px;height:\(h)px;background:#0e0f1f">
          \(line(date, topTop, topFS, "#9698b4"))
          \(line(hhmm, bigTop, bigFS, accent))
          \(line(ss, secTop, secFS, "#7d8cff"))
          \(line("tina watch", brandTop, brandFS, "#2b41e6"))
        </body>
        """
    }
}
