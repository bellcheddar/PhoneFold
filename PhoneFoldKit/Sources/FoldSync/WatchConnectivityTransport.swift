#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity
import Synchronization

/// The real link: `WCSession`, behind the protocol so nothing else has to know that.
///
/// **Two channels, and choosing between them per message is the whole job.**
///
/// - **Commands** go by `sendMessage`, which is immediate and only works while the other device
///   is reachable. A pause that arrives thirty seconds late is worse than one that never
///   arrives, because the fold has moved on and the user has already pressed it again.
/// - **State** goes by `updateApplicationContext`, which the system coalesces: only the most
///   recent survives, and it is delivered when the other side next wakes. That is exactly right
///   for a snapshot that changes sixty times a second, and it is why the phone can publish
///   freely without filling a queue.
///
/// Sending state as messages instead would queue every frame and deliver a backlog of stale
/// states minutes later, which is the failure this split exists to avoid.
public final class WatchConnectivityTransport: NSObject, FoldRemote.Transport, @unchecked Sendable {

    private let link = Mutex<RemoteLink?>(nil)
    private let session: WCSession

    /// Whether this device can talk to the other one at all.
    ///
    /// On iOS a Watch may be paired but have no app installed; on watchOS the phone may simply
    /// be out of range. Both are "not reachable" to a caller, and the remote shows a transport
    /// that says so rather than buttons that quietly do nothing.
    public var isReachable: Bool { session.isReachable }

    public init?(session: WCSession = .default) {
        guard WCSession.isSupported() else { return nil }
        self.session = session
        super.init()
        session.delegate = self
        session.activate()
    }

    /// Attach the link this transport feeds. Set after construction because the two refer to
    /// each other.
    public func attach(_ link: RemoteLink) {
        self.link.withLock { $0 = link }
    }

    public func send(_ command: FoldRemote.Command) {
        guard session.isReachable else { return }
        // No reply handler and no error handler beyond ignoring it: a command that fails to
        // send is a command the user will press again, and an alert about WatchConnectivity
        // would be the app explaining its own plumbing.
        session.sendMessage(command.payload, replyHandler: nil, errorHandler: nil)
    }

    public func update(_ state: FoldRemote.State) {
        // `updateApplicationContext` throws when the session is not activated. That is not
        // worth surfacing: the handshake re-sends on reachability, so a state lost here is
        // replaced within moments by one that is not.
        try? session.updateApplicationContext(state.payload)
    }
}

extension WatchConnectivityTransport: WCSessionDelegate {

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                        error: Error?) {
        link.withLock { $0 }?.reachabilityChanged(to: session.isReachable)
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        link.withLock { $0 }?.reachabilityChanged(to: session.isReachable)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        link.withLock { $0 }?.received(payload: message)
    }

    public func session(_ session: WCSession,
                        didReceiveApplicationContext applicationContext: [String: Any]) {
        link.withLock { $0 }?.received(payload: applicationContext)
    }

    #if os(iOS) || os(visionOS)
    // Required wherever a session can be *re*-paired, which is iOS and visionOS but not
    // watchOS. Both are about switching to a different Watch, and reactivating is the whole
    // correct response: the new device knows nothing, and the handshake hands it the current
    // state as soon as it is reachable.
    //
    // The guard said `os(iOS)` until visionOS was built, where the protocol requires exactly
    // the same two members and the conformance failed with a message naming neither of them.
    // A platform guard is a claim about every platform, not only the one in front of you.
    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
#endif
