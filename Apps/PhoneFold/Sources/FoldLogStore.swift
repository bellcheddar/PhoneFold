import Foundation
import Combine
import FoldEngine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The folds this account has run, following it between devices.
///
/// PLAN.md's cross-platform gate: "iCloud trajectory sync round-trips between two Simulators."
///
/// **`NSUbiquitousKeyValueStore`, not CloudKit and not a document.** What syncs is a list of
/// descriptions - see `FoldLog` for why it is descriptions rather than coordinates - and that
/// is a few kilobytes: a full forty-entry log with long accessions and a long device name
/// encodes to well under 100 kB against the store's 1 MB. CloudKit for that would be a
/// container, a schema and an account state to handle, for data that fits in a key.
///
/// **Merged on every change, never overwritten.** Two devices can both run folds while offline,
/// so neither list is authoritative; the store hands over whatever arrived and this merges it
/// with what is here. Writing this device's list over the top is how the other device's
/// afternoon disappears, silently and permanently.
@MainActor
final class FoldLogStore: ObservableObject {

    @Published private(set) var log = FoldLog()
    /// Why the list is not following this account around, when it is not.
    ///
    /// **Said, because every way this fails is silent.** Without the
    /// `ubiquity-kvstore-identifier` entitlement `NSUbiquitousKeyValueStore` accepts a write
    /// and returns nil on the read; with the entitlement but nobody signed into iCloud it does
    /// the same. Neither errors, and the feature is simply inert - which is indistinguishable
    /// from a device that has nothing to sync yet.
    @Published private(set) var problem: String?

    private let store = NSUbiquitousKeyValueStore.default
    /// The subscription to iCloud's "somebody else changed this" notification.
    ///
    /// A Combine cancellable rather than an `NSObjectProtocol` token, because the token would
    /// have to be removed in `deinit` and a `deinit` is nonisolated: reaching a main-actor
    /// property from one is a compile error under strict concurrency, and the ways round it
    /// are all worse than not needing to. A cancellable cancels itself when this is released.
    private var observer: AnyCancellable?

    /// What this device calls itself in the list.
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #elseif canImport(AppKit)
        return Host.current().localizedName ?? "Mac"
        #else
        return "This device"
        #endif
    }

    init() {
        // The only honest test of "is iCloud there" available before anything is written.
        if FileManager.default.ubiquityIdentityToken == nil {
            problem = "Not signed in to iCloud, so folds stay on this device."
        }
        load()
        observer = NotificationCenter.default
            .publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                       object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // `assumeIsolated` off the main thread is an assertion, not a check - it traps.
                // `.receive(on: .main)` is what makes this true rather than asserted.
                MainActor.assumeIsolated { self?.load() }
            }
        // Asking is free and the answer arrives as the notification above. Without it a device
        // that has been away sees its own log until something else happens to change.
        store.synchronize()
    }

    /// Take what iCloud has and merge it with what is here.
    private func load() {
        guard let data = store.data(forKey: FoldLog.storeKey),
              let remote = FoldLog.decoded(from: data) else {
            // Nothing there, or something there that will not decode. Either way this device's
            // log stands: an unreadable remote must never empty a local one.
            return
        }
        let merged = log.merged(with: remote)
        guard merged != log else { return }
        log = merged
        // Written back, because the merge may have taught the account something the other
        // device did not know: this device's own folds.
        save()
    }

    /// Note that a fold has been played.
    func record(_ fold: FoldHandoff) {
        log.record(FoldLog.Entry(fold: fold, date: Date(), device: Self.deviceName))
        save()
    }

    private func save() {
        guard let data = try? log.encoded() else { return }
        store.set(data, forKey: FoldLog.storeKey)
    }
}
