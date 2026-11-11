//
//  KeychainManager.swift
//  lumasight
//
//  Minimal Keychain cleanup helper for detecting and deleting legacy
//  Keychain entries (`com.jonathan.glance`) without ever reading, exporting,
//  or prompting for secrets.
//

import Foundation
import LocalAuthentication
import Security

enum KeychainError: LocalizedError, Equatable {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

nonisolated enum KeychainLookupState: Equatable, Sendable {
    case present
    case notFound
    case inaccessible(OSStatus)
}

/// Protocol abstraction so privacy cleanup logic can be tested without touching
/// the user's real macOS Keychain.
nonisolated protocol KeychainStoreProtocol: Sendable {
    func exists(account: String) -> Bool
    func lookupState(account: String) -> KeychainLookupState
    func delete(account: String) throws
}

extension KeychainStoreProtocol {
    func lookupState(account: String) -> KeychainLookupState {
        exists(account: account) ? .present : .notFound
    }
}

nonisolated struct SystemKeychainStore: KeychainStoreProtocol {
    static let shared = SystemKeychainStore()
    static let defaultService = "com.jonathan.glance"

    let service: String

    init(service: String = defaultService) {
        self.service = service
    }

    func exists(account: String) -> Bool {
        lookupState(account: account) == .present
    }

    /// Attributes-only, non-interactive existence check — never prompts the user
    /// and never reads secret payloads (`kSecReturnData` is omitted).
    func lookupState(account: String) -> KeychainLookupState {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return .present
        case errSecItemNotFound:
            return .notFound
        default:
            return .inaccessible(status)
        }
    }

    /// Deletes a legacy generic password entry by service + account.
    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }
}

enum KeychainManager {
    nonisolated static let service = SystemKeychainStore.defaultService

    nonisolated static func exists(account: String) -> Bool {
        SystemKeychainStore.shared.exists(account: account)
    }

    nonisolated static func delete(account: String) throws {
        try SystemKeychainStore.shared.delete(account: account)
    }
}
