import Foundation
import SwiftUI
import WatchKit

// The watch runs the Tina4 engine ITSELF: libtina4watch.a renders HTML to an
// RGBA buffer with the pure-Pascal software rasterizer (Tina4RasterCanvas), and
// we wrap that buffer in a UIImage for SwiftUI. No phone, no network — the same
// engine, HTML and events as every other Tina4 surface, now on the wrist.
//
// (The renderer has no glyph rasterizer yet, so this demo document is built from
// shapes — divs, backgrounds, border-radius — exactly the kind of watch UI the
// engine draws crisply. Text glyphs are a native-canvas follow-up.)
final class EngineModel: ObservableObject {
    static let shared = EngineModel()

    @Published var frame: UIImage?
    private var winked = false
    private var started = false

    // The watch's own point size × screen scale = the pixel buffer we render.
    private var points: CGSize { WKInterfaceDevice.current().screenBounds.size }
    private var scale: CGFloat { WKInterfaceDevice.current().screenScale }

    func start() {
        guard !started else { return }
        started = true
        // Bring up the FPC runtime once, then bind a canvas at our pixel size.
        PASCALMAIN()
        let w = Int(points.width * scale), h = Int(points.height * scale)
        tina4watch_init(Int32(w), Int32(h))
        render()
    }

    // A tap on the wrist → the real engine event path, plus a visible response:
    // toggle the wink and re-render. On a document with registered onclick
    // actions, tina4watch_touch would fire them; here it exercises hit-testing
    // and we drive the wink from the host so the interaction is visible.
    func tap() {
        WKInterfaceDevice.current().play(.click)
        let mid = Float(points.width * scale) / 2
        _ = tina4watch_touch(0, mid, mid)   // down
        _ = tina4watch_touch(1, mid, mid)   // up
        winked.toggle()
        render()
    }

    func render() {
        let w = Int(points.width * scale), h = Int(points.height * scale)
        let html = Self.smiley(w: w, h: h, winked: winked)
        html.withCString { tina4watch_set_html($0) }
        guard let buf = tina4watch_render(Int32(w), Int32(h), 1.0) else { return }
        if let img = Self.image(from: buf, w: w, h: h, scale: scale) {
            frame = img
        }
    }

    // Wrap the engine's $AARRGGBB (little-endian → BGRA) top-left-origin buffer as
    // an opaque CGImage. The watch UI fills the screen with a solid background, so
    // we display it opaque (alpha skipped) — no premultiply mismatch.
    private static func image(from buf: UnsafeMutableRawPointer, w: Int, h: Int, scale: CGFloat) -> UIImage? {
        let bytes = w * h * 4
        let data = Data(bytes: buf, count: bytes)   // copy: the engine reuses its buffer next frame
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    // Size-everything-from-the-screen smiley (ported from the render server) so it
    // fits any watch. All shapes — the engine draws these 1:1.
    private static func smiley(w: Int, h: Int, winked: Bool) -> String {
        let face = Int(Double(min(w, h)) * 0.74)
        let fl = (w - face) / 2, ft = (h - face) / 2
        let eye = Int(Double(face) * 0.15)
        let eyeY = ft + Int(Double(face) * 0.30)
        let eL = fl + Int(Double(face) * 0.24)
        let eR = fl + face - Int(Double(face) * 0.24) - eye
        var leH = eye, leY = eyeY
        if winked { leH = max(4, Int(Double(eye) * 0.25)); leY = eyeY + (eye - leH) / 2 }
        let mW = Int(Double(face) * 0.50), mH = Int(Double(face) * 0.30)
        let mL = fl + (face - mW) / 2, mT = ft + Int(Double(face) * 0.54)
        let dk = "#15162e"
        // px radii (= half the box) for circles. Use the 4-value form — the raster
        // path rounds explicit per-corner px radii (single-value shorthand and % are
        // not expanded for these boxes yet; the mouth already relies on 4-value).
        let fr = face / 2, er = eye / 2
        func r(_ v: Int) -> String { "\(v)px \(v)px \(v)px \(v)px" }
        return """
        <body style="margin:0;width:\(w)px;height:\(h)px;background:#0e0f1f">
          <div style="position:absolute;left:\(fl)px;top:\(ft)px;width:\(face)px;height:\(face)px;border-radius:\(r(fr));background:#ffd23c"></div>
          <div style="position:absolute;left:\(eR)px;top:\(eyeY)px;width:\(eye)px;height:\(eye)px;border-radius:\(r(er));background:\(dk)"></div>
          <div style="position:absolute;left:\(eL)px;top:\(leY)px;width:\(eye)px;height:\(leH)px;border-radius:\(r(er));background:\(dk)"></div>
          <div style="position:absolute;left:\(mL)px;top:\(mT)px;width:\(mW)px;height:\(mH)px;background:\(dk);border-radius:\(mH/6)px \(mH/6)px \(mH)px \(mH)px"></div>
          <div style="position:absolute;left:\(mL)px;top:\(mT)px;width:\(mW)px;height:\(mH/2)px;background:#ffd23c"></div>
        </body>
        """
    }
}
