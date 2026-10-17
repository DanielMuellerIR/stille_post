/// Unbestätigte Ergebnisse bleiben in Zustellreihenfolge im RAM. Ein später
/// beendeter Auftrag darf die noch offene Vorschau nicht ersetzen.
public struct PendingResults<Value> {
    public private(set) var current: Value?
    private var waiting: [Value] = []
    public init() {}
    public var isEmpty: Bool { current == nil && waiting.isEmpty }

    /// true bedeutet: Das Ergebnis ist sofort anzuzeigen.
    public mutating func append(_ value: Value) -> Bool {
        if current == nil { current = value; return true }
        waiting.append(value)
        return false
    }

    @discardableResult public mutating func finish() -> Value? {
        current = waiting.isEmpty ? nil : waiting.removeFirst()
        return current
    }
}
