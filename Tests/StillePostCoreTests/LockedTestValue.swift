import Foundation

final class LockedTestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var snapshot: Value { lock.withLock { value } }

    @discardableResult
    func update<T>(_ change: (inout Value) -> T) -> T {
        lock.withLock { change(&value) }
    }
}
