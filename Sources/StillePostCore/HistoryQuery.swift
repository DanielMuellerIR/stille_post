import Foundation

/// Ausschließlich lokale Suche; Datumsgrenzen folgen Kalendertagen statt
/// festen Stundenabständen und bleiben dadurch auch am Zeitwechsel korrekt.
public struct HistoryQuery: Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable { case all, successful, failed }
    public enum Period: String, CaseIterable, Sendable { case all, today, lastSevenDays, lastThirtyDays }

    public var text = ""
    public var status: Status = .all
    public var period: Period = .all

    public init() {}

    public func filter(_ entries: [HistoryStore.Entry], now: Date = Date(),
                       calendar: Calendar = .current) -> [HistoryStore.Entry] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let today = calendar.startOfDay(for: now)
        let dayCount: Int
        switch period {
        case .all: dayCount = 0
        case .today: dayCount = 1
        case .lastSevenDays: dayCount = 7
        case .lastThirtyDays: dayCount = 30
        }
        let start = calendar.date(byAdding: .day, value: 1 - dayCount, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        var matches: [HistoryStore.Entry] = []
        for entry in entries {
            if Task.isCancelled { return [] }
            if status == .failed && !entry.isFailed { continue }
            if status == .successful && entry.isFailed { continue }
            if dayCount > 0 && !(entry.date >= start && entry.date < end) { continue }
            let searchable = entry.rawText + "\n" + entry.cleanText
            if words.allSatisfy({ searchable.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }) {
                matches.append(entry)
            }
        }
        return matches
    }
}
