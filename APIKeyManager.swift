//
//  ApiKeyManager.swift
//  Eye~Helpi
//
//  FinTech-grade secure storage for API keys:
//  - values live in the Keychain, readable only on this device while unlocked
//    (kSecAttrAccessibleWhenUnlockedThisDeviceOnly) and never iCloud-synced
//  - the bundled ENCRYPTED_KEYS.plist bootstrap decrypts with AES-GCM under an
//    HKDF-derived key (v2 scheme: SHA-256 of the project name -> HKDF)
//  - nothing secret is ever logged, and the Setup UI wipes the pasteboard
//    after every key save
//

import Foundation
import Security
import CryptoKit

final class ApiKeyManager {

    // MARK: - Singleton

    static let shared = ApiKeyManager()

    private init() {
        // Re-run the bundle bootstrap on first launch: empty values are
        // skipped, so user-entered Keychain values are never overwritten
        // by a blank plist entry.
        initializeKeysFromEncryptedFile()
    }

    // MARK: - Properties

    private var service: String {
        Bundle.main.bundleIdentifier ?? "com.projectname.apiKeys"
    }

    private let initializationKey = "ApiKeyManager_Initialized"

    // MARK: - Public API

    /// Reads a key from the Keychain (nil when absent).
    func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// True when the key exists in the Keychain.
    func has(key: String) -> Bool {
        get(key: key) != nil
    }

    /// Writes a key to the Keychain: device-only, readable while unlocked.
    @discardableResult
    func set(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Bootstrap

    private func initializeKeysFromEncryptedFile() {
        if UserDefaults.standard.bool(forKey: initializationKey) {
            return
        }

        guard let bundlePath = Bundle.main.path(forResource: "ENCRYPTED_KEYS", ofType: "plist"),
              let plistData = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            UserDefaults.standard.set(true, forKey: initializationKey)
            return
        }

        var successCount = 0
        for (key, encryptedValue) in plist {
            guard let encryptedString = encryptedValue as? String,
                  !encryptedString.isEmpty,
                  let decryptedValue = decryptValue(encryptedString) else {
                continue
            }
            if set(key: key, value: decryptedValue) {
                successCount += 1
            }
        }

        UserDefaults.standard.set(true, forKey: initializationKey)
        print("ApiKeyManager: bootstrapped \(successCount)/\(plist.count) keys from the encrypted bundle file.")
    }

    // MARK: - Crypto

    private func decryptValue(_ encryptedValue: String) -> String? {
        guard let encryptedData = Data(base64Encoded: encryptedValue) else {
            return nil
        }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            return nil
        }
        do {
            let decryptedData = try AES.GCM.open(sealedBox, using: Self.deriveKey())
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// HKDF(SHA-256(project name), salt: "Eye~Helpi.enc.v2", info: "aes-gcm") -> 32-byte AES key.
    /// v2 upgrades the original bare-SHA-256 key with a proper extract-and-expand KDF.
    private static func deriveKey() -> SymmetricKey {
        let projectName = Bundle.main.bundleIdentifier?
            .components(separatedBy: ".")
            .last ?? "Eye-Helpi"
        let ikm = SymmetricKey(data: SHA256.hash(data: Data(projectName.utf8)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("Eye~Helpi.enc.v2".utf8),
            info: Data("aes-gcm.key".utf8),
            outputByteCount: 32
        )
    }
}