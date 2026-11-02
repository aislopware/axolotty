import Foundation

/// A minimal main-actor multicast: views subscribe and keep the token; dropping
/// the token unsubscribes. (Explicit change events suit AppKit's imperative
/// updates better than property observation, e.g. outline-view diffs.)
final class Signal<Value> {
    private var observers: [Int: (Value) -> Void] = [:]
    private var next = 0

    func observe(_ body: @escaping (Value) -> Void) -> SignalToken {
        next += 1
        let id = next
        observers[id] = body
        return SignalToken { [weak self] in self?.observers[id] = nil }
    }

    func emit(_ value: Value) {
        for body in Array(observers.values) { body(value) }
    }
}

extension Signal where Value == Void {
    func emit() { emit(()) }
}

final class SignalToken {
    private var cancel: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    func invalidate() {
        cancel?()
        cancel = nil
    }

    isolated deinit { cancel?() }
}
