//
//  SecureHTTP.swift
//  Eye~Helpi
//
//  FinTech-grade TLS for outbound cloud traffic (OpenAI fallback brain):
//  - a dedicated URLSession with TLS 1.2 minimum
//  - server trust is always fully evaluated; a failed evaluation cancels
//  - optional SPKI certificate pinning driven by TLS_PINS.plist:
//      <dict>
//          <key>api.openai.com</key>
//          <array><string>SHA-256-base64 pin</string></array>
//      </dict>
//    Pins may be EC P-256 SPKI hashes (SHA-256 of the standard SPKI wrapper)
//    or full certificate DER hashes. While TLS_PINS.plist is absent, standard
//    App Store-grade trust applies (pinning is off). See TLS_PINS.plist.example.
//

import CryptoKit
import Foundation
import Security

enum SecureHTTP {

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: TrustDelegate(), delegateQueue: nil)
    }()
}

final class TrustDelegate: NSObject, URLSessionDataDelegate {

    private let pins: [String: [String]]

    override init() {
        pins = TrustDelegate.loadPins()
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            // Chain failed system trust evaluation - fail closed.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Optional pin enforcement: any presented pin matching the set passes.
        let expected = Set(pins[challenge.protectionSpace.host] ?? [])
        if !expected.isEmpty {
            let presented = Set(certificatePinHashes(in: trust))
            if presented.isDisjoint(with: expected) {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    // MARK: - Pin collection

    /// SHA-256 base64 pins for every certificate in the presented chain:
    /// the EC P-256 SPKI hash plus the full-certificate DER hash as fallback.
    private func certificatePinHashes(in trust: SecTrust) -> [String] {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return []
        }
        return chain.compactMap { certificate in
            var hashes: [String] = []

            if let certData = SecCertificateCopyData(certificate) as Data? {
                hashes.append(Self.base64SHA256(certData))
            }

            if let key = SecCertificateCopyKey(certificate),
               let attrs = SecKeyCopyAttributes(key) as? [String: Any],
               (attrs[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
               let external = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                // Uncompressed EC point -> standard P-256 SPKI wrapper header.
                let header: [UInt8] = [
                    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce,
                    0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
                    0x03, 0x01, 0x07
                ]
                var spki = Data(header)
                spki.append(external)
                hashes.append(Self.base64SHA256(spki))
            }

            return hashes.first
        }
    }

    private static func base64SHA256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func loadPins() -> [String: [String]] {
        guard let url = Bundle.main.url(forResource: "TLS_PINS", withExtension: "plist"),
              let raw = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return [:]
        }
        return dict.compactMapValues { $0 as? [String] }
    }
}