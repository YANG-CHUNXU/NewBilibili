import Foundation
import Security

enum SessdataKeychainError: Error {
    case unexpectedStatus(OSStatus)
}

final class SessdataKeychainStore: @unchecked Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "com.ycx.newbi.bilibili",
        account: String = "SESSDATA"
    ) {
        self.service = service
        self.account = account
    }

    func readSessdata() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func saveSessdata(_ sessdata: String) throws {
        let data = Data(sessdata.utf8)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SessdataKeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw SessdataKeychainError.unexpectedStatus(addStatus)
        }
    }

    func deleteSessdata() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessdataKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
