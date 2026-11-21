import Foundation

enum OllamaKeepAlive: Encodable, Equatable {
    case seconds(Int)
    case duration(String)

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .seconds(let seconds): try value.encode(seconds)
        case .duration(let duration): try value.encode(duration)
        }
    }
}

struct CleanupChatMessage: Encodable {
    enum Role: String, Encodable { case system, user }
    let role: Role
    let content: String
}

struct OllamaOptions: Encodable {
    enum CodingKeys: String, CodingKey {
        case contextSize = "num_ctx"
        case threadCount = "num_thread"
        case temperature
        case repeatPenalty = "repeat_penalty"
    }
    let contextSize: Int
    let threadCount: Int?
    let temperature: Int?
    let repeatPenalty: Double?
}

struct OllamaWarmUpRequest: Encodable {
    enum CodingKeys: String, CodingKey { case model, prompt, keepAlive = "keep_alive", options }
    let model: String
    let prompt = ""
    let keepAlive: OllamaKeepAlive
    let options: OllamaOptions
}

struct OllamaChatRequest: Encodable {
    enum CodingKeys: String, CodingKey { case model, stream, think, keepAlive = "keep_alive", options, messages }
    let model: String
    let stream: Bool
    // Für die Textbereinigung bringt Thinking hohe Latenz ohne Qualitätsgewinn.
    let think = false
    let keepAlive: OllamaKeepAlive
    let options: OllamaOptions
    let messages: [CleanupChatMessage]
}

struct CleanupResponseMessage: Decodable {
    let content: String
}

struct OllamaChatResponse: Decodable {
    let message: CleanupResponseMessage
}

struct OpenAIChatRequest: Encodable {
    let model: String
    let temperature = 0
    let messages: [CleanupChatMessage]
}

struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable { let message: CleanupResponseMessage }
    // Nur die erste Wahl gehört zu diesem Auftrag. Ein ungültiges späteres
    // Element darf eine brauchbare erste Antwort nicht entwerten.
    let first: Choice?

    init(from decoder: Decoder) throws {
        enum Key: String, CodingKey { case choices }
        let response = try decoder.container(keyedBy: Key.self)
        var choices = try response.nestedUnkeyedContainer(forKey: .choices)
        first = choices.isAtEnd ? nil : try choices.decode(Choice.self)
    }
}
