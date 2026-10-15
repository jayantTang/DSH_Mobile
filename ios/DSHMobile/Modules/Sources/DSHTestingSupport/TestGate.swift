import Foundation

/// A gate a test opens when it wants to: an in-flight call parks on ``wait()``
/// until the test calls ``open()``.
///
/// Why a test needs one: a fake carrier answers instantly, so any state that
/// only exists *while* a call is in flight (`SettingsModel.SaveState.saving`)
/// is gone before the caller can look at it. Pairing a gate with `GatedCarrier`
/// turns that race into an ordinary await.
///
/// Test-only: no product target depends on `DSHTestingSupport`.
public actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Suspends until the gate is opened; returns immediately once it is.
    public func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                // `open()` ran between the check above and here.
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// Lets every parked waiter through. Later ``wait()`` calls do not suspend.
    public func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
