//
//  TagRead.swift
//  Eye~Helpi
//
//  NFC tag reading: hold the phone to an NDEF tag and Eye~Helpi reports
//  what it points to (URLs, text, smart-device handovers). Real iPhone
//  only — the simulator has no NFC hardware.
//
//  IMPORTANT HONEST LIMIT: NFC *payments* are not possible in any
//  third-party iOS app. Apple Pay / Wallet is locked to the Secure
//  Element — Apple does not allow apps to emulate cards or initiate
//  payments over NFC. Seamless tag handovers (tap-to-read, device
//  onboarding) are what we support.
//

import CoreNFC
import Foundation

@MainActor
final class TagRead: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate {

    @Published var lastRead: String?
    @Published var isReading = false
    @Published var error: String?

    private var session: NFCNDEFReaderSession?
    private var resume: CheckedContinuation<String?, Never>?

    func readTag() async -> String? {
        error = nil
        lastRead = nil
        isReading = true
        defer { isReading = false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.resume = continuation
            // On modern SDKs this initializer is non-failable; a session with
            // no NFC hardware simply invalidates itself with an error, which
            // the delegate reports through finish(with:).
            let session = NFCNDEFReaderSession(
                delegate: self,
                queue: nil,
                invalidateAfterFirstRead: true
            )
            session.alertMessage = "Hold your iPhone near the NDEF tag."
            self.session = session
            session.begin()
        }
    }

    private func finish(with result: String?) {
        if let result {
            lastRead = result
        }
        resume?.resume(returning: result)
        resume = nil
        session = nil
    }
}

// NFCNDEFReaderSessionDelegate — delivers what the tag holds.
extension TagRead {

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        var texts: [String] = []
        for message in messages {
            for record in message.records {
                let (text, _) = record.wellKnownTypeTextPayload()
                if let text {
                    texts.append(text)
                } else {
                    // URI record: first payload byte is the prefix code, the
                    // rest is the URL text. Parsed from bytes on purpose.
                    let payload = record.payload
                    if payload.count > 1, let suffix = String(data: payload.dropFirst(), encoding: .utf8),
                       !suffix.isEmpty {
                        texts.append(suffix)
                    }
                }
            }
        }
        Task { @MainActor in
            self.finish(with: texts.isEmpty ? nil : texts.joined(separator: " | "))
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            // "Session invalidated by user" is the normal cancel path, not an error.
            let userCancelled = error.localizedDescription.contains("invalidated by the user")
            if self.resume != nil {
                if !userCancelled {
                    self.error = error.localizedDescription
                }
                self.finish(with: nil)
            }
        }
    }
}