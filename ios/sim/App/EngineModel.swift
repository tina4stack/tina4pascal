import Foundation
import SwiftUI
import UIKit

// The iOS Simulator runs the Tina4 engine ITSELF: libtina4iossim.a renders HTML
// to an RGBA buffer with the pure-Pascal software rasterizer (Tina4RasterCanvas)
// and we wrap that buffer in a UIImage for SwiftUI. FPC 3.2.2 has no simulator
// target, so this is the PATCHED trunk compiler's `iphonesim` target at work —
// the same engine, HTML and events as every other Tina4 surface, now without a
// physical iPhone.
//
// The page is a live clock plus a small HTML card, so you can watch the engine
// lay out and rasterize real HTML on the Simulator every second.
final class EngineModel: ObservableObject {
    static let shared = EngineModel()

    @Published var frame: UIImage?
    private var started = false
    private var timer: Timer?
    private var accentPink = false            // tap toggles the accent

    private var points: CGSize { UIScreen.main.bounds.size }
    private var scale: CGFloat { UIScreen.main.scale }

    func start() {
        guard !started else { return }
        started = true
        PASCALMAIN()                          // bring up the FPC runtime once
        let w = Int(points.width * scale), h = Int(points.height * scale)
        tina4sim_init(Int32(w), Int32(h))
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    // A tap → the engine event path + a visible response (swap the accent colour).
    func tap(at p: CGPoint) {
        let x = Float(p.x * scale), y = Float(p.y * scale)
        _ = tina4sim_touch(0, x, y)
        _ = tina4sim_touch(1, x, y)
        accentPink.toggle()
        render()
    }

    func render() {
        let w = Int(points.width * scale), h = Int(points.height * scale)
        let html = page(w: w, h: h, accentPink: accentPink)
        html.withCString { tina4sim_set_html($0) }
        // We already work in DEVICE PIXELS (points × scale), so the engine draws
        // at 1:1 — density 1.0, exactly like the watch host. Passing the screen
        // scale here would lay the page out at 3× the canvas (background fills
        // only the top-left third).
        guard let buf = tina4sim_render(Int32(w), Int32(h), 1.0) else { return }
        if let img = Self.image(from: buf, w: w, h: h, scale: scale) { frame = img }
    }

    // Wrap the engine's $AARRGGBB (little-endian → BGRA) top-left-origin buffer
    // as an opaque CGImage.
    private static func image(from buf: UnsafeMutableRawPointer, w: Int, h: Int, scale: CGFloat) -> UIImage? {
        let data = Data(bytes: buf, count: w * h * 4)     // copy: the engine reuses its buffer
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    // A Tina4-styled page: a live HH:MM:SS clock over a rounded card, the date
    // and a brand line — every glyph, the rounded fill and the gradient drawn by
    // the pure-Pascal raster path (Tina4RasterCanvas).
    private func page(w: Int, h: Int, accentPink: Bool) -> String {
        let now = Date()
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .month, .day, .weekday], from: now)
        func p2(_ v: Int) -> String { String(format: "%02d", v) }
        let hhmmss = "\(p2(c.hour ?? 0)):\(p2(c.minute ?? 0)):\(p2(c.second ?? 0))"
        let days = ["", "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let dow = days[(c.weekday ?? 1)]
        let date = "\(dow) \(p2(c.month ?? 0))-\(p2(c.day ?? 0))"
        let accent = accentPink ? "#ff5aa0" : "#ffd23c"

        let cardTop = Int(Double(h) * 0.30)
        let cardH = Int(Double(h) * 0.24)
        let cardMargin = Int(Double(w) * 0.06)
        let cardW = w - cardMargin * 2
        let bigFS = Int(Double(h) * 0.075)
        let clockTop = cardTop + (cardH - bigFS) / 2 - Int(Double(h) * 0.01)
        let dateTop = Int(Double(h) * 0.20)
        let dateFS = Int(Double(h) * 0.028)
        let titleTop = Int(Double(h) * 0.10)
        let titleFS = Int(Double(h) * 0.045)
        let brandFS = Int(Double(h) * 0.032)
        let brandTop = cardTop + cardH + Int(Double(h) * 0.04)

        func line(_ txt: String, _ top: Int, _ fs: Int, _ col: String, _ weight: String = "bold") -> String {
            "<div style=\"position:absolute;left:0px;top:\(top)px;width:\(w)px;text-align:center;"
            + "font-size:\(fs)px;font-weight:\(weight);color:\(col)\">\(txt)</div>"
        }
        let card = "<div style=\"position:absolute;left:\(cardMargin)px;top:\(cardTop)px;"
            + "width:\(cardW)px;height:\(cardH)px;border-radius:\(Int(Double(cardH) * 0.28))px;"
            + "background:#16172c;border:2px solid #2b41e6\"></div>"
        return """
        <body style="margin:0;width:\(w)px;height:\(h)px;background:#0e0f1f">
          \(line("TINA4 ON iOS-SIM", titleTop, titleFS, "#7d8cff"))
          \(line(date, dateTop, dateFS, "#9698b4"))
          \(card)
          \(line(hhmmss, clockTop, bigFS, accent))
          \(line("native pascal engine - tap to wink", brandTop, brandFS, "#5b5c78", "500"))
        </body>
        """
    }
}
