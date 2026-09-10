import Foundation
import SwiftUI
import WatchConnectivity

// Receives engine-rendered frames from the paired iPhone over WatchConnectivity
// and forwards taps back. The phone runs the Tina4 engine, renders the watch
// HTML to RGBA -> JPEG, and sends it here; we never render HTML on the watch
// (FPC has no watchOS slice — see docs/WATCH.md).
final class StreamModel: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = StreamModel()

    @Published var frame: UIImage?      // latest frame from the phone
    @Published var reachable = false

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
    }

    // The wrist tapped at (x,y) in points — forward to the phone so its engine
    // dispatches the tap and pushes the next frame.
    func sendTap(x: CGFloat, y: CGFloat) {
        guard let s = session, s.isReachable else { return }
        s.sendMessage(["tapX": Double(x), "tapY": Double(y)],
                      replyHandler: nil, errorHandler: nil)
    }

    // MARK: WCSessionDelegate
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.reachable = s.isReachable }
    }
    func sessionReachabilityDidChange(_ s: WCSession) {
        DispatchQueue.main.async { self.reachable = s.isReachable }
    }
    // A frame pushed as raw JPEG/PNG bytes.
    func session(_ s: WCSession, didReceiveMessageData data: Data) {
        if let img = UIImage(data: data) {
            DispatchQueue.main.async { self.frame = img }
        }
    }
    // Or as a keyed message carrying the image under "frame".
    func session(_ s: WCSession, didReceiveMessage message: [String : Any]) {
        if let data = message["frame"] as? Data, let img = UIImage(data: data) {
            DispatchQueue.main.async { self.frame = img }
        }
    }
}
