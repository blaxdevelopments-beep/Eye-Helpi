//
//  EyeVoice.swift
//  Eye~Helpi
//
//  The voice: AVSpeechSynthesizer with an en-AU voice, so Eye~Helpi talks
//  back in its own accent. Enabled state persists; speaking is interruptible
//  (a new utterance replaces the one in flight).
//

import AVFoundation

@MainActor
final class EyeVoice: NSObject, ObservableObject {

    static let shared = EyeVoice()

    @Published private(set) var isSpeaking = false

    /// Persisted preference: should Eye~Helpi talk?
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "eyehelpi.voice.enabled")
            if !isEnabled { stop() }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        isEnabled = UserDefaults.standard.bool(forKey: "eyehelpi.voice.enabled")
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks the text (en-AU), replacing anything already speaking.
    func speak(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-AU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

extension EyeVoice: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}