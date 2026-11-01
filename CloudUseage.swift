//
//  CloudUsage.swift
//  Eye~Helpi
//
//  Tracks approximate OpenAI fallback usage (cloud turns, characters in/out,
//  estimated tokens) so the cloud never bills silently. Counters persist in
//  UserDefaults - never any message content.
//

import Foundation

@MainActor
final class CloudUsage: ObservableObject {

    static let shared = CloudUsage()

    private enum Keys {
        static let requests = "eyehelpi.cloud.requests"
        static let charsSent = "eyehelpi.cloud.charsSent"
        static let charsReceived = "eyehelpi.cloud.charsReceived"
    }

    @Published private(set) var requests: Int
    @Published private(set) var charsSent: Int
    @Published private(set) var charsReceived: Int

    private init() {
        let defaults = UserDefaults.standard
        requests = defaults.integer(forKey: Keys.requests)
        charsSent = defaults.integer(forKey: Keys.charsSent)
        charsReceived = defaults.integer(forKey: Keys.charsReceived)
    }

    /// Rough token estimate: ~4 characters per token for chat traffic.
    var estimatedTokens: Int {
        (charsSent + charsReceived) / 4
    }

    func record(charsSent: Int, charsReceived: Int) {
        requests += 1
        self.charsSent += charsSent
        self.charsReceived += charsReceived
        persist()
    }

    func reset() {
        requests = 0
        charsSent = 0
        charsReceived = 0
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(requests, forKey: Keys.requests)
        defaults.set(charsSent, forKey: Keys.charsSent)
        defaults.set(charsReceived, forKey: Keys.charsReceived)
    }
}