import Foundation
import Security
import Combine

final class KeychainStore: ObservableObject {
    private let service = "uk.co.heskethwebdesign.PorchKeep"
    private let usernameAccount = "eufy-username"
    private let passwordAccount = "eufy-password"

    var hasCredentials: Bool {
        return readString(account: usernameAccount) != nil && readString(account: passwordAccount) != nil
    }

    var username: String? { readString(account: usernameAccount) }
    var password: String? { readString(account: passwordAccount) }

    func saveCredentials(username: String, password: String) {
        save(account: usernameAccount, value: username)
        save(account: passwordAccount, value: password)
    }

    func clear() {
        delete(account: usernameAccount)
        delete(account: passwordAccount)
    }

    private func save(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    private func readString(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}
