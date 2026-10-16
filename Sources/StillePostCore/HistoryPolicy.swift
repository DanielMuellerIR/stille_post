import Foundation

public extension Config {
    struct History: Codable, Equatable, Sendable {
        public var storeText = true
        /// 0 bedeutet unbegrenzte Textaufbewahrung.
        public var textRetentionDays = 0
        /// 0 behält Fehleraufnahmen bis zur ausdrücklichen manuellen Löschung.
        public var audioRetentionDays = 0

        public init() {}

        public var isValid: Bool {
            [0, 1, 7, 30].contains(textRetentionDays) && [0, 7, 30].contains(audioRetentionDays)
        }

        public func applying(to entry: HistoryStore.Entry, calendar: Calendar = .current) -> HistoryStore.Entry {
            var result = entry
            result.storesText = storeText
            result.textExpiresAt = deadline(days: textRetentionDays, from: entry.date, calendar: calendar)
            result.audioExpiresAt = deadline(days: audioRetentionDays, from: entry.date, calendar: calendar)
            return result
        }

        private func deadline(days: Int, from date: Date, calendar: Calendar) -> Date? {
            guard days > 0 else { return nil }
            return calendar.date(byAdding: .day, value: days, to: date)
        }

        private enum CodingKeys: String, CodingKey { case storeText, textRetentionDays, audioRetentionDays }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Eine ausdrücklich vorhandene, aber unlesbare Datenschutzwahl darf
            // nicht unbeabsichtigt zum dauerhaften Textspeichern zurückfallen.
            storeText = c.contains(.storeText) ? ((try? c.decode(Bool.self, forKey: .storeText)) ?? false) : true
            textRetentionDays = c.contains(.textRetentionDays) ? ((try? c.decode(Int.self, forKey: .textRetentionDays)) ?? 1) : 0
            audioRetentionDays = (try? c.decode(Int.self, forKey: .audioRetentionDays)) ?? 0
            if ![0, 1, 7, 30].contains(textRetentionDays) { textRetentionDays = 1 }
            if ![0, 7, 30].contains(audioRetentionDays) { audioRetentionDays = 0 }
        }
    }
}
