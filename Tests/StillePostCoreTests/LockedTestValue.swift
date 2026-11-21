import Foundation
import XCTest

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

func awaitTestExpectations(_ expectations: [XCTestExpectation], timeout: TimeInterval,
                         file: StaticString = #filePath, line: UInt = #line) async {
    let result = await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
    XCTAssertEqual(result, .completed, expectations.map(\.expectationDescription).joined(separator: ", "),
                   file: file, line: line)
}
