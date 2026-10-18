import Foundation

public enum LocalModelFailure: Error, Equatable, Sendable {
    case invalidCatalog, storage, insufficientSpace, integrity, invalidResponse, download, busy, missing, alreadyInstalled, loading, recognition

    public var messageKey: String {
        switch self {
        case .invalidCatalog: return "model.error.catalog"
        case .storage: return "model.error.storage"
        case .insufficientSpace: return "model.error.space"
        case .integrity: return "model.error.integrity"
        case .invalidResponse: return "model.error.response"
        case .download: return "model.error.download"
        case .busy: return "model.error.busy"
        case .missing: return "model.error.missing"
        case .alreadyInstalled: return "model.error.installed"
        case .loading: return "model.error.loading"
        case .recognition: return "model.error.recognition"
        }
    }
}

public struct LocalModelFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String
    public let url: URL

    public init(path: String, size: Int64, sha256: String, url: URL) {
        self.path = path; self.size = size; self.sha256 = sha256; self.url = url
    }
}

public struct LocalModelCatalog: Codable, Equatable, Sendable {
    public let model: String
    public let revision: String
    public let files: [LocalModelFile]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    // Die Reserve bleibt nach dem Download für die gerätespezifische CoreML-Aufbereitung frei.
    public static let workingReserveBytes: Int64 = 2_147_483_648

    public init(model: String, revision: String, files: [LocalModelFile]) throws {
        self.model = model; self.revision = revision; self.files = files
        try validate()
    }

    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "iphone-model", withExtension: "json") else {
            throw LocalModelFailure.invalidCatalog
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        guard !model.isEmpty, model.utf8.count < 128, Self.isHex(revision, length: 40),
              !files.isEmpty, files.count <= 64, Set(files.map(\.path)).count == files.count else {
            throw LocalModelFailure.invalidCatalog
        }
        var bytes: Int64 = 0
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !file.path.contains("\\"), !file.path.hasSuffix(".part"), file.path.utf8.count <= 256,
                  file.path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }),
                  file.size > 0, file.size <= 2_000_000_000, Self.isHex(file.sha256, length: 64),
                  Self.isPinnedSource(file.url),
                  file.url.path.contains(revision) || file.path.hasPrefix("tokenizer/") else {
                throw LocalModelFailure.invalidCatalog
            }
            bytes += file.size
        }
        for first in files {
            guard !files.contains(where: { $0.path.hasPrefix(first.path + "/") }) else {
                throw LocalModelFailure.invalidCatalog
            }
        }
        guard bytes <= 2_000_000_000 else { throw LocalModelFailure.invalidCatalog }
    }

    private static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isPinnedSource(_ url: URL) -> Bool {
        let components = url.path.split(separator: "/")
        guard url.scheme == "https", url.host == "huggingface.co", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let resolve = components.firstIndex(of: "resolve"), resolve + 1 < components.count else { return false }
        return isHex(String(components[resolve + 1]), length: 40)
    }
}
