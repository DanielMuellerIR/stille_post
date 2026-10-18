import SwiftUI
import VisionKit
import AVFoundation
import StillePostClientCore

struct PairingScanner: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraReady: Bool?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Group {
                if cameraReady == nil {
                    ProgressView()
                } else if cameraReady == true && !failed {
                    ScannerController(onScan: onScan, onFailure: { failed = true }).ignoresSafeArea(edges: .bottom)
                } else {
                    Text("error.cameraUnavailable").padding()
                }
            }
            .navigationTitle("connection.scan")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } } }
        }.privacySensitive()
            .task {
                guard DataScannerViewController.isSupported else { cameraReady = false; return }
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                cameraReady = allowed && DataScannerViewController.isAvailable
            }
    }
}

private struct ScannerController: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onFailure: onFailure) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { DispatchQueue.main.async { onFailure() } }
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let onFailure: () -> Void
        private var completed = false
        init(onScan: @escaping (String) -> Void, onFailure: @escaping () -> Void) { self.onScan = onScan; self.onFailure = onFailure }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { onFailure() }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !completed else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    completed = true; dataScanner.stopScanning(); onScan(payload); return
                }
            }
        }
    }
}
