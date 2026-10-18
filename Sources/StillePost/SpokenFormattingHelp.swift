import SwiftUI
import StillePostCore

struct SpokenFormattingHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("formatting.help"))
            Text(L10n.text("formatting.examples"))
            Text(L10n.text("formatting.literal_help"))
        }
        .font(.caption).foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
