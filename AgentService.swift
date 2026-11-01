//
//  AgentService.swift
//  Eye~Helpi
//
//  Talks to the local Eye~Helpi agent's Ollama server (the same server the
//  Python agent in eye_helpi_agent/ uses). Implements the /api/chat and
//  /api/tags endpoints with streaming, mirroring main.py's chat loop.
//  Cloud fallback traffic goes through SecureHTTP (TLS 1.2+, optional pins).
//

import Foundation

struct OllamaMessage: Codable {
    let role: String
    let content: String
    var images: [String]? = nil
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
}

private struct OllamaStreamChunk: Decodable {
    struct Message: Decodable {
        let content: String
    }
    let message: Message?
    let done: Bool
}

struct AgentService {

    var host: String

    private var baseURL: URL {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a host saved without its scheme, so a typed LAN address
        // still connects instead of silently falling back to the default.
        let lowered = trimmed.lowercased()
        if !trimmed.isEmpty, !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: trimmed) ?? URL(string: AgentConfig.defaultHost)!
    }

    // MARK: - Connection check

    /// Returns the model names the local Ollama server has pulled.
    /// A short timeout keeps the "is my brain reachable" check snappy: an
    /// unreachable host fails in seconds instead of hanging for a minute.
    func availableModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)

        struct TagsResponse: Decodable {
            struct Model: Decodable {
                let name: String
            }
            let models: [Model]
        }
        return try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
    }

    // MARK: - Chat

    /// Streams one chat turn, trying the local Ollama host first. When the
    /// host cannot be reached (and no part of the reply has streamed yet) and
    /// an OpenAI key is stored, it falls back to the cloud brain so the phone
    /// keeps working away from the desktop agent.
    /// `onDelta` is called per piece of text; `onBrain` fires once ("ollama"
    /// or "cloud") on the main actor. Returns the full reply.
    func streamChat(
        messages: [OllamaMessage],
        onDelta: @escaping (String) -> Void,
        onBrain: ((String) -> Void)? = nil
    ) async throws -> String {
        var streamedAny = false

        // Deep-think routes to the larger cloud brain first, with the local
        // Ollama brain as the safety net if the cloud refuses.
        if UserDefaults.standard.bool(forKey: "eyehelpi.deepThink"),
           let preferred = OpenAIFallbackService() {
            do {
                let reply = try await preferred.streamChat(messages: messages, onDelta: onDelta)
                await CloudUsage.shared.record(
                    charsSent: Self.approximateCharCount(messages),
                    charsReceived: reply.count
                )
                await MainActor.run { onBrain?("cloud") }
                return reply
            } catch {
                // Cloud refused from the start - fall through to the local brain.
            }
        }

        do {
            let reply = try await streamOllamaChat(messages: messages) { delta in
                streamedAny = true
                onDelta(delta)
            }
            await MainActor.run { onBrain?("ollama") }
            return reply
        } catch {
            // A half-streamed reply cannot be replayed by the fallback.
            guard !streamedAny, let fallback = OpenAIFallbackService() else { throw error }
            do {
                let reply = try await fallback.streamChat(messages: messages, onDelta: onDelta)
                await CloudUsage.shared.record(
                    charsSent: Self.approximateCharCount(messages),
                    charsReceived: reply.count
                )
                await MainActor.run { onBrain?("cloud") }
                return reply
            } catch let fallbackError {
                throw AgentServiceError.bothBrainsFailed(
                    ollama: error.localizedDescription,
                    openAI: fallbackError.localizedDescription
                )
            }
        }
    }

    /// Rough outbound size, used only for the usage estimate (images dominate).
    private static func approximateCharCount(_ messages: [OllamaMessage]) -> Int {
        messages.reduce(0) { count, message in
            count + message.content.count
                + (message.images?.reduce(0) { $0 + $1.count } ?? 0)
        }
    }

    private func streamOllamaChat(
        messages: [OllamaMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(model: AgentConfig.modelName, messages: messages, stream: true)
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AgentServiceError.badResponse(status: status)
        }

        var fullReply = ""
        for try await line in bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OllamaStreamChunk.self, from: lineData),
                  let text = chunk.message?.content, !text.isEmpty else {
                continue
            }
            fullReply += text
            onDelta(text)
            TelemetryHub.shared.recordToken()
        }
        return fullReply
    }
}

enum AgentServiceError: LocalizedError {
    case badResponse(status: Int)
    case openAIRejected(status: Int, message: String, requestID: String?)
    case bothBrainsFailed(ollama: String, openAI: String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            return "Ollama answered with HTTP \(status)"
        case .openAIRejected(let status, let message, let requestID):
            var text = "OpenAI rejected the cloud call (HTTP \(status))"
            if !message.isEmpty {
                text += ": \(message)"
            }
            if let requestID {
                text += " — request ID \(requestID) (OpenAI support can trace this)"
            }
            return text
        case .bothBrainsFailed(let ollama, let openAI):
            return "Ollama failed (\(ollama)) and the OpenAI fallback failed (\(openAI))."
        }
    }
}