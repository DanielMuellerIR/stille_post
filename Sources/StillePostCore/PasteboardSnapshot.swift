#if canImport(AppKit)
import AppKit

/// Tiefe Kopie einer macOS-Zwischenablage. `NSPasteboardItem` selbst darf nach
/// `clearContents()` nicht als Backup dienen; deshalb werden die Bytes jedes
/// Typs jedes Items ausdrücklich kopiert.
public struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    /// Stellt nur dann wieder her, wenn seit dem eigenen Clipboard-Schreibzugriff
    /// weder der Nutzer noch eine andere App einen neueren Inhalt abgelegt hat.
    @discardableResult
    public func restore(to pasteboard: NSPasteboard, ifChangeCountIs expected: Int) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let restored = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
        return true
    }
}
#endif
