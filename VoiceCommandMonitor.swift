//
//  VoiceCommandMonitor.swift
//  Eye~Helpi
//
//  On-device speech recognition (SFSpeechRecognizer, en-AU): listens for
//  trigger words like "analyse" and fires the analysis callback. Uses the
//  microphone via AVAudioEngine. Permissions live in Info.plist.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class VoiceCommandMonitor: NSObject, ObservableObject {

    @Published var isListening = false
    @Published var heard = ""
    @Published var status = ""

    var onTrigger: (() -> Void)?

    // Both are loaded lazily: the recognizer pulls in locale assets and the
    // engine reserves audio hardware, and neither belongs on the app's launch
    // path - they are only needed once listening actually starts.
    private lazy var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private lazy var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let triggerWords = ["analyse", "analyze", "what do you see", "describe"]

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    func startListening() {
        AVAudioApplication.requestRecordPermission { granted in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    guard status == .authorized, granted else {
                        self.status = "Speech or microphone permission was denied."
                        return
                    }
                    self.beginListening()
                }
            }
        }
    }

    private func beginListening() {
        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, _ in
                guard let self, let text = result?.bestTranscription.formattedString, !text.isEmpty else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.heard = text
                    let lowered = text.lowercased()
                    if self.triggerWords.contains(where: { lowered.contains($0) }) {
                        self.status = "Trigger heard - analysing what I see."
                        self.onTrigger?()
                    }
                }
            }

            isListening = true
            status = "Listening... say \"analyse\"."
        } catch {
            status = "Could not start the microphone: \(error.localizedDescription)"
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        status = ""
    }
}