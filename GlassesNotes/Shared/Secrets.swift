// Secrets.swift
// Centralized API key storage. NEVER hardcode keys in source — use this instead.
//
// Lookup order (first non-empty match wins):
//   1. ProcessInfo.environment[name.rawValue]   — for Xcode tests / CI / launch args
//   2. Keychain (kSecClassGenericPassword)      — for app runtime; persists across launches
//
// App runtime:
//   try Secrets.set(.openAI, value: userPastedKey)   // once, e.g. from a settings screen
//   let key = try Secrets.require(.openAI)
//
// Xcode tests:
//   Scheme → Test → Arguments → Environment Variables → OPENAI_API_KEY = sk-...
//   let key = try Secrets.require(.openAI)
//
// Why both: env vars give a friction-free dev/test loop; Keychain is the only
// place on iOS where it is safe to persist a long-lived credential across
// app launches (file-protected, never backed up to iCloud unencrypted).

import Foundation
import Security

enum Secrets {

    /// Named secret slots. `rawValue` doubles as the env-var name and the
    /// Keychain account name, so swapping storage backends never desyncs them.
    enum Name: String {
        case openAI = "OPENAI_API_KEY"
        case gemini = "GEMINI_API_KEY"

        fileprivate var account: String { rawValue }
        fileprivate var service: String { "com.glassesnotes.secrets" }
    }

    enum SecretError: Error, LocalizedError {
        case notFound(Name)
        case keychainStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound(let n):
                return "Missing secret '\(n.rawValue)'. Set the env var (tests) "
                     + "or call Secrets.set(.\(n)) at runtime (app)."
            case .keychainStatus(let s):
                return "Keychain operation failed (OSStatus=\(s))"
            }
        }
    }

    // MARK: - Lookup

    /// Returns the secret if present; throws SecretError.notFound otherwise.
    static func require(_ name: Name) throws -> String {
        if let env = ProcessInfo.processInfo.environment[name.rawValue],
           !env.isEmpty {
            return env
        }
        if let kc = try keychainRead(name), !kc.isEmpty {
            return kc
        }
        throw SecretError.notFound(name)
    }

    /// Returns the secret or nil if missing. Silent variant of `require`.
    static func get(_ name: Name) -> String? {
        try? require(name)
    }

    /// True if a key is available from either source.
    static func has(_ name: Name) -> Bool {
        get(name) != nil
    }

    // MARK: - Storage (app runtime only — tests should use env vars)

    /// Write or overwrite the secret in the Keychain.
    /// `kSecAttrAccessibleAfterFirstUnlock` lets background tasks read it after
    /// the user has unlocked the device at least once since boot.
    static func set(_ name: Name, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: name.service,
            kSecAttrAccount as String: name.account,
        ]
        SecItemDelete(query as CFDictionary)  // idempotent overwrite

        var add = query
        add[kSecValueData as String]      = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecretError.keychainStatus(status)
        }
    }

    /// Remove the secret from the Keychain. No-op if absent.
    static func delete(_ name: Name) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: name.service,
            kSecAttrAccount as String: name.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.keychainStatus(status)
        }
    }

    // MARK: - Private

    private static func keychainRead(_ name: Name) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: name.service,
            kSecAttrAccount as String: name.account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str  = String(data: data, encoding: .utf8) else { return nil }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw SecretError.keychainStatus(status)
        }
    }
}
