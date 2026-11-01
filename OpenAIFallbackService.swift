//
//  OpenAIFallbackService.swift
//  Eye~Helpi
//
//  Cloud fallback brain: when the local Ollama host cannot be reached,
//  Eye~Helpi answers through the OpenAI API instead, so the phone keeps
//  working away from the desktop agent. The key never touches code - it is
//  read from the Keychain via ApiKeyManager. Traffic runs through SecureHTTP
//  (TLS 1.2+, optional SPKI pinning).
//

import Foundation

struct OpenAIFallbackService {

    static let keyName = "OPENAI_API_KEY"
    static let standardModelName = "gpt-4o-mini"

    /// Deep-think mode routes questions to the larger cloud brain; otherwise
    /// the fast standard model answers.
    static var modelName: String {
        UserDefaults.standard.bool(forKey: "eyehelpi.deepThink") ? "gpt-4o" : standardModelName
    }

    private let apiKey: String

    /// Nil when no usable key is stored, so callers can skip the fallback.
    init?(apiKey: String? = ApiKeyManager.shared.get(key: OpenAIFallbackService.keyName)) {
        guard let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        self.apiKey = trimmed
    }

    /// Streams one chat turn from OpenAI, mirroring AgentService.streamChat.
    func streamChat(
        messages: [OllamaMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(model: Self.modelName, messages: messages.map(Self.map), stream: true)
        )

        let (bytes, response) = try await SecureHTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentServiceError.badResponse(status: -1)
        }
        guard http.statusCode == 200 else {
            // Capture OpenAI's error payload and request ID so failures are
            // actionable (the ID is what OpenAI support asks for).
            let detail = await Self.collectErrorDetail(from: bytes, response: http)
            throw AgentServiceError.openAIRejected(
                status: http.statusCode,
                message: detail.message,
                requestID: detail.requestID
            )
        }

        var fullReply = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
                  let text = chunk.choices.first?.delta.content, !text.isEmpty else {
                continue
            }
            fullReply += text
            onDelta(text)
            TelemetryHub.shared.recordToken()
        }
        return fullReply
    }

    // MARK: - Connection check

    /// Auth check against the cloud: `valid` when the stored key is accepted.
    /// `detail` carries OpenAI's rejection reason and request ID when refused.
    /// Throws when the cloud itself cannot be reached at all.
    func isKeyValid() async throws -> (valid: Bool, detail: String?) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await SecureHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentServiceError.badResponse(status: -1)
        }
        switch http.statusCode {
        case 200:
            return (true, nil)
        case 401, 403:
            let detail = Self.collectErrorBody(data, response: http)
            return (false, detail ?? "the key was rejected")
        default:
            throw AgentServiceError.badResponse(status: http.statusCode)
        }
    }

    // MARK: - Error detail capture

    /// Extracts OpenAI's error message and request ID from a failed response
    /// so the app shows WHY the cloud refused, not just a status code.
    private static func collectErrorBody(_ data: Data, response: HTTPURLResponse) -> String? {
        var parts: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let text = error["message"] as? String {
            parts.append(text)
        }
        if let requestID = response.value(forHTTPHeaderField: "x-request-id") {
            parts.append("request ID \(requestID) — quote it if you contact OpenAI support")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private static func collectErrorDetail(from bytes: URLSession.AsyncBytes, response: HTTPURLResponse) async -> (message: String, requestID: String?) {
        var raw = ""
        do {
            for try await line in bytes.lines {
                raw += line + "\n"
                if raw.count > 2000 { break }
            }
        } catch {
            // Body unreadable - report the status alone.
        }
        let detail = collectErrorBody(Data(raw.utf8), response: response)
        guard let detail else { return ("", nil) }
        // Split so the thrown error keeps message and ID separate.
        if let range = detail.range(of: " — request ID "),
           raw.hasPrefix("{") {
            let message = String(detail[..<range.lowerBound])
            let requestID = String(detail[range.upperBound...])
                .replacingOccurrences(of: " — quote it if you contact OpenAI support", with: "")
            return (message, requestID)
        }
        return (detail, nil)
    }

    // MARK: - Request mapping

    private struct OpenAIChatRequest: Encodable {
        let model: String
        let messages: [OpenAIMessage]
        let stream: Bool
    }

    private struct OpenAIMessage: Encodable {
        let role: String
        let content: OpenAIContent
    }

    /// OpenAI takes plain text for text turns and an array of text/image parts
    /// when images are attached, so the encoder picks the shape per message.
    private enum OpenAIContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    private struct ContentPart: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        static func text(_ value: String) -> ContentPart {
            ContentPart(type: "text", text: value, imageURL: nil)
        }

        static func image(base64: String) -> ContentPart {
            ContentPart(
                type: "image_url",
                text: nil,
                imageURL: ImageURL(url: "data:image/jpeg;base64,\(base64)")
            )
        }
    }

    private struct ImageURL: Encodable {
        let url: String
    }

    private static func map(_ message: OllamaMessage) -> OpenAIMessage {
        let role: String
        switch message.role {
        case "assistant": role = "assistant"
        case "system": role = "system"
        default: role = "user"
        }
        guard let images = message.images, !images.isEmpty else {
            return OpenAIMessage(role: role, content: .text(message.content))
        }
        var parts = [ContentPart.text(message.content)]
        parts += images.map { ContentPart.image(base64: $0) }
        return OpenAIMessage(role: role, content: .parts(parts))
    }

    // MARK: - Response

    private struct OpenAIStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta
        }
        let choices: [Choice]
    }
}