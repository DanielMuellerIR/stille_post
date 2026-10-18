import Foundation
import CryptoKit
import CoreML

/// Fester, separat beschaffter Modellstand aus dem lokalen Vergleich. Kein SDK
/// und kein automatischer Download beim Aufnahmestart.
public enum SileroModel {
    public static let revision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    public static let name = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    public static var directory: URL {
        Config.appSupportDir.appendingPathComponent("models/silero-\(revision)/\(name)")
    }
    struct FileSpec {
        let name: String
        let bytes: Int
        let sha256: String
    }
    static let files: [FileSpec] = [
        .init(name: "analytics/coremldata.bin", bytes: 243, sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
        .init(name: "coremldata.bin", bytes: 625, sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
        .init(name: "metadata.json", bytes: 3335, sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
        .init(name: "model.mil", bytes: 176918, sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
        .init(name: "weights/weight.bin", bytes: 882304, sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063")
    ]

    public enum Failure: Error, LocalizedError {
        case missing, integrity, unavailable, download
        public var errorDescription: String? {
            switch self {
            case .missing: return L10n.text("vad.fallback.missing")
            case .integrity: return L10n.text("vad.fallback.integrity")
            case .unavailable: return L10n.text("vad.fallback.unavailable")
            case .download: return L10n.text("vad.download_failed")
            }
        }
    }

    /// Typ/Größe vor dem Lesen prüfen, damit auch eine FIFO nicht blockieren kann.
    static func verifiedData(_ url: URL, spec: FileSpec) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue == spec.bytes else { throw Failure.integrity }
        let data = try Data(contentsOf: url)
        try verify(data, spec: spec)
        return data
    }

    static func verify(_ data: Data, spec: FileSpec) throws {
        guard data.count == spec.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == spec.sha256 else {
            throw Failure.integrity
        }
    }

    static func validate(at directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { throw Failure.missing }
        do {
            for folder in [directory, directory.appendingPathComponent("analytics"), directory.appendingPathComponent("weights")] {
                guard (try manager.attributesOfItem(atPath: folder.path))[.type] as? FileAttributeType == .typeDirectory else {
                    throw Failure.integrity
                }
            }
            for file in files { _ = try verifiedData(directory.appendingPathComponent(file.name), spec: file) }
        } catch { throw Failure.integrity }
    }

    public static func availability() async -> String? {
        await Task.detached {
            do { try validate(at: directory); return nil }
            catch let error as Failure { return error.localizedDescription }
            catch { return Failure.integrity.localizedDescription }
        }.value
    }

    /// Die UI ruft dies nur über den beschrifteten Downloadknopf auf. Der Actor
    /// verhindert konkurrierende Installationen aus mehreren Settings-Ansichten.
    public static func install() async throws { try await installer.install() }
    private static let installer = Installer()
    private actor Installer {
        private var busy = false
        func install() async throws {
            guard !busy else { throw Failure.download }
            busy = true
            defer { busy = false }
            try await SileroModel.install(at: directory, fetch: download)
        }
    }

    static func install(at directory: URL, fetch: (FileSpec) async throws -> Data) async throws {
        if (try? validate(at: directory)) != nil { return }
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".silero-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for file in files {
            try Task.checkCancellation()
            let data = try await fetch(file)
            try Task.checkCancellation()
            try verify(data, spec: file)
            let target = staging.appendingPathComponent(file.name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        try validate(at: staging)
        try Task.checkCancellation()
        // Ein beschädigter Stand wird erhalten statt rekursiv gelöscht. Die
        // Veröffentlichung selbst ist eine Umbenennung auf demselben Volume.
        if manager.fileExists(atPath: directory.path) {
            if (try? validate(at: directory)) != nil { return }
            try manager.moveItem(at: directory, to: parent.appendingPathComponent(".silero-invalid-\(UUID().uuidString)"))
        }
        try manager.moveItem(at: staging, to: directory)
    }

    private static func download(_ file: FileSpec) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/\(revision)/\(name)/\(file.name)")!
        let (stream, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= Int64(file.bytes) else { throw Failure.download }
        var data = Data()
        data.reserveCapacity(file.bytes)
        for try await byte in stream {
            guard data.count < file.bytes else { throw Failure.integrity }
            data.append(byte)
        }
        return data
    }
}

protocol SpeechActivityDetector: AnyObject {
    var frameSize: Int { get }
    func isSpeech(_ samples: [Float]) throws -> Bool
}

/// Eine Instanz gehört genau einer Aufnahmephase. Pause/Fortsetzen beginnt mit
/// leeren Rekurrenzzuständen und 64 Nullsamples; Segmentgrenzen setzen sie nicht zurück.
final class SileroSpeechDetector: SpeechActivityDetector {
    let frameSize = 4096
    private let model: MLModel
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = [Float](repeating: 0, count: 64)

    init(directory: URL) throws {
        try SileroModel.validate(at: directory)
        let configuration = MLModelConfiguration()
        // Derselbe CPU-Pfad auf älteren Macs; keine ANE-/macOS-14-SDK-Abhängigkeit.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: directory, configuration: configuration)
        hidden = try Self.zeros(128)
        cell = try Self.zeros(128)
    }

    private static func zeros(_ count: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)
        for i in 0..<count { array[i] = 0 }
        return array
    }

    func isSpeech(_ samples: [Float]) throws -> Bool {
        guard !samples.isEmpty, samples.count <= frameSize, samples.allSatisfy({ $0.isFinite }) else {
            throw SileroModel.Failure.unavailable
        }
        let audio = try Self.zeros(4160)
        for i in 0..<64 { audio[i] = NSNumber(value: context[i]) }
        for i in samples.indices { audio[64 + i] = NSNumber(value: samples[i]) }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": audio, "hidden_state": hidden, "cell_state": cell
        ])
        let output = try model.prediction(from: input)
        guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
              probability.count == 1,
              let nextHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let nextCell = output.featureValue(for: "new_cell_state")?.multiArrayValue,
              nextHidden.count == 128, nextCell.count == 128 else { throw SileroModel.Failure.unavailable }
        let value = probability[0].doubleValue
        guard value.isFinite, (0...1).contains(value),
              (0..<128).allSatisfy({ nextHidden[$0].doubleValue.isFinite && nextCell[$0].doubleValue.isFinite }) else {
            throw SileroModel.Failure.unavailable
        }
        hidden = nextHidden
        cell = nextCell
        context = Array(samples.suffix(64))
        if context.count < 64 { context = Array(repeating: 0, count: 64 - context.count) + context }
        // Die Schwelle stammt aus dem festgelegten AP17-Vergleich.
        return value >= 0.85
    }
}

extension VadSegmenter {
    public static func prepared(config: Config.Vad, modelDirectory: URL = SileroModel.directory) async -> VadSegmenter {
        guard config.detector == .silero else { return VadSegmenter(config: config) }
        return await Task.detached {
            do { return VadSegmenter(config: config, detector: try SileroSpeechDetector(directory: modelDirectory)) }
            catch let error as SileroModel.Failure {
                return VadSegmenter(config: config, detector: nil, fallbackReason: error.localizedDescription)
            } catch {
                return VadSegmenter(config: config, detector: nil,
                    fallbackReason: L10n.text("vad.fallback.unavailable"))
            }
        }.value
    }
}
