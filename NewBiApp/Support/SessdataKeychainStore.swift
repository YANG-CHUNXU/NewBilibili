import Foundation
import os
import Security

enum SessdataKeychainError: Error {
    case unexpectedStatus(OSStatus)
    case invalidPayload
}

enum SessdataReadResult {
    case found(String)
    case notFound
    case failure(SessdataKeychainError)
}

final class SessdataKeychainStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.ycx.newbi", category: "SessdataKeychain")

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
        switch readSessdataResult() {
        case .found(let sessdata):
            return sessdata
        case .notFound, .failure:
            return nil
        }
    }

    func readSessdataResult(logFailures: Bool = false) -> SessdataReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .notFound
        default:
            return makeReadFailure(.unexpectedStatus(status), logFailures: logFailures)
        }

        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return makeReadFailure(.invalidPayload, logFailures: logFailures)
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return makeReadFailure(.invalidPayload, logFailures: logFailures)
        }
        return .found(trimmed)
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

    private func makeReadFailure(
        _ error: SessdataKeychainError,
        logFailures: Bool
    ) -> SessdataReadResult {
        if logFailures {
            logReadFailure(error)
        }
        return .failure(error)
    }

    private func logReadFailure(_ error: SessdataKeychainError) {
        switch error {
        case .unexpectedStatus(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
            Self.logger.error(
                "Keychain read failed [service=\(self.service, privacy: .public) account=\(self.account, privacy: .public) status=\(status) message=\(message, privacy: .public)]"
            )
        case .invalidPayload:
            Self.logger.error(
                "Keychain read returned invalid payload [service=\(self.service, privacy: .public) account=\(self.account, privacy: .public)]"
            )
        }
    }
}
