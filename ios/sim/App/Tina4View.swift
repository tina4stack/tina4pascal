import UIKit
import SwiftUI

// The iOS Simulator runs the Tina4 engine ITSELF with its NATIVE canvas: the
// same Tina4ShellIOS (Core Graphics shapes + Core Text glyphs) the physical
// iPhone uses, now on the Simulator via the patched FPC `iphonesim` target and
// the univint bindings built for it (docs/fpc-iphonesim.md). The engine paints
// straight into this UIView's drawRect context — device-identical, system fonts
// and anti-aliasing, no pixel blit.
final class Tina4View: UIView {
    private var started = false
    private var timer: Timer?
    private var imgObserver: NSObjectProtocol?     // retain the block observer, else it's torn down
    private var accentPink = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Load the bundled showcase page (rich, self-contained HTML) if present;
    // otherwise fall back to the generated live clock.
    private lazy var bundledHTML: String? =
        Bundle.main.url(forResource: "demo", withExtension: "html")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        PASCALMAIN()                                   // bring up the FPC runtime once
        // resolve relative <img src> (e.g. "tina4.png") against the app bundle
        if let res = Bundle.main.resourcePath {
            res.withCString { tina4sim_native_set_asset_base($0) }
        }
        // a remote <img> downloads asynchronously (ImageLoader.m); repaint when it
        // lands so the shell decodes the now-cached file.
        imgObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("Tina4ImageReady"), object: nil, queue: .main) { [weak self] _ in
            self?.setNeedsDisplay()
        }
        loadHTML()
        setNeedsDisplay()
        // Only tick for the live clock; the static showcase needs no timer.
        if bundledHTML == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.loadHTML(); self?.setNeedsDisplay()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if started { loadHTML(); setNeedsDisplay() }   // reload at the real bounds
    }

    // A drawRect context is top-left / y-down and in POINTS, matching the engine's
    // CSS-px space — so hand it the point size and density 1, exactly like the
    // device host (ios/app/Tina4View.m). UIKit backs the view at native scale, so
    // Core Graphics/Core Text draw sharp on Retina automatically.
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = Int(bounds.width), h = Int(bounds.height)
        tina4sim_native_frame(ctx, Int32(w), Int32(h), 1.0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        _ = tina4sim_native_touch(0, Float(p.x), Float(p.y))
        _ = tina4sim_native_touch(1, Float(p.x), Float(p.y))
        accentPink.toggle()
        loadHTML(); setNeedsDisplay()
    }

    private func loadHTML() {
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { return }
        let html = bundledHTML ?? page(w: w, h: h, accentPink: accentPink)
        html.withCString { tina4sim_native_set_html($0) }
    }

    // A Tina4-styled page: a live HH:MM:SS clock in a rounded card, the date and a
    // brand line — now drawn with real system fonts and anti-aliasing (Core Text),
    // not the raster 7-segment font.
    private func page(w: Int, h: Int, accentPink: Bool) -> String {
        let now = Date()
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .month, .day, .weekday], from: now)
        func p2(_ v: Int) -> String { String(format: "%02d", v) }
        let hhmmss = "\(p2(c.hour ?? 0)):\(p2(c.minute ?? 0)):\(p2(c.second ?? 0))"
        let days = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let dow = days[(c.weekday ?? 1)]
        let date = "\(dow) \(p2(c.month ?? 0))-\(p2(c.day ?? 0))"
        let accent = accentPink ? "#ff5aa0" : "#ffd23c"

        let cardTop = Int(Double(h) * 0.30)
        let cardH = Int(Double(h) * 0.22)
        let cardMargin = Int(Double(w) * 0.07)
        let cardW = w - cardMargin * 2
        let bigFS = Int(Double(h) * 0.07)
        let clockTop = cardTop + (cardH - bigFS) / 2 - Int(Double(h) * 0.012)
        let dateTop = Int(Double(h) * 0.21)
        let dateFS = Int(Double(h) * 0.026)
        let titleTop = Int(Double(h) * 0.11)
        let titleFS = Int(Double(h) * 0.040)
        let brandFS = Int(Double(h) * 0.028)
        let brandTop = cardTop + cardH + Int(Double(h) * 0.045)

        func line(_ txt: String, _ top: Int, _ fs: Int, _ col: String, _ weight: String = "bold") -> String {
            "<div style=\"position:absolute;left:0px;top:\(top)px;width:\(w)px;text-align:center;"
            + "font-family:sans-serif;font-size:\(fs)px;font-weight:\(weight);color:\(col)\">\(txt)</div>"
        }
        let card = "<div style=\"position:absolute;left:\(cardMargin)px;top:\(cardTop)px;"
            + "width:\(cardW)px;height:\(cardH)px;border-radius:\(Int(Double(cardH) * 0.28))px;"
            + "background:#16172c;border:2px solid #2b41e6\"></div>"
        return """
        <body style="margin:0;width:\(w)px;height:\(h)px;background:#0e0f1f">
          \(line("Tina4 on iOS Simulator", titleTop, titleFS, "#7d8cff"))
          \(line(date, dateTop, dateFS, "#9698b4", "500"))
          \(card)
          \(line(hhmmss, clockTop, bigFS, accent))
          \(line("native Core Graphics engine - tap to wink", brandTop, brandFS, "#5b5c78", "500"))
        </body>
        """
    }
}

// SwiftUI wrapper so @main can host the UIView.
struct Tina4ViewRep: UIViewRepresentable {
    func makeUIView(context: Context) -> Tina4View {
        let v = Tina4View()
        DispatchQueue.main.async { v.startIfNeeded() }
        return v
    }
    func updateUIView(_ uiView: Tina4View, context: Context) {}
}
