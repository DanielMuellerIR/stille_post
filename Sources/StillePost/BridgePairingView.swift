import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import StillePostCore

struct BridgePairingView: View {
    let address: String
    let fingerprint: String
    let image: NSImage
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("settings.bridge.pair_title")).font(.title2.bold())
            Text(L10n.text("settings.bridge.pair_instruction")).fixedSize(horizontal: false, vertical: true)
            Image(nsImage: image).interpolation(.none).resizable().frame(width: 300, height: 300)
                .padding(16).background(Color.white).frame(maxWidth: .infinity).accessibilityLabel(L10n.text("settings.bridge.qr_accessibility"))
            Text(address).font(.callout).textSelection(.enabled)
            Text(L10n.text("settings.bridge.fingerprint")).font(.caption)
            Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("settings.bridge.qr_secret")).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(L10n.text("common.close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 460).privacySensitive()
            .task { try? await Task.sleep(nanoseconds: 120_000_000_000); dismiss() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in dismiss() }
    }

    static func qrImage(data: Data) throws -> NSImage {
        let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else {
            throw BridgeIdentity.IdentityError.invalid
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension Notification.Name {
    static let bridgeCredentialsChanged = Notification.Name("StillePost.bridgeCredentialsChanged")
}
