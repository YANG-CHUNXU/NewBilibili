import Foundation
import Security
import os
import NewBiCore

enum BiliCredentialKeychainError: Error {
    case unexpectedStatus(OSStatus)
    case invalidPayload
}

enum BiliCredentialReadResult {
    case found(BiliCredential)
    case notFound
    case failure(BiliCredentialKeychainError)
}

final class BiliCredentialKeychainStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.ycx.newbi", category: "BiliCredentialKeychain")

    private let service: String
    private let account: String

    init(
        service: String = "com.ycx.newbi.bilibili",
        account: String = "CREDENTIAL"
    ) {
        self.service = service
        self.account = account
    }

    func readCredential() -> BiliCredential? {
        switch readCredentialResult() {
        case .found(let credential):
            return credential
        case .notFound, .failure:
            return nil
        }
    }

    func readCredentialResult(logFailures: Bool = false) -> BiliCredentialReadResult {
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

        guard let data = item as? Data else {
            return makeReadFailure(.invalidPayload, logFailures: logFailures)
        }

        do {
            let credential = try JSONDecoder().decode(BiliCredential.self, from: data)
            let normalized = try normalize(credential)
            return .found(normalized)
        } catch {
            return makeReadFailure(.invalidPayload, logFailures: logFailures)
        }
    }

    func saveCredential(_ credential: BiliCredential) throws {
        let normalized = try normalize(credential)
        let data = try JSONEncoder().encode(normalized)

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
                throw BiliCredentialKeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw BiliCredentialKeychainError.unexpectedStatus(addStatus)
        }
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiliCredentialKeychainError.unexpectedStatus(status)
        }
    }

    func migrateLegacySessdataIfNeeded(_ legacyStore: SessdataKeychainStore) {
        guard readCredential() == nil, let legacySessdata = legacyStore.readSessdata() else {
            return
        }
        let credential = BiliCredential(
            sessdata: legacySessdata,
            biliJct: nil,
            dedeUserID: nil,
            updatedAt: Date()
        )
        do {
            try saveCredential(credential)
        } catch {
            return
        }
    }

    private func normalize(_ credential: BiliCredential) throws -> BiliCredential {
        let sessdata = credential.sessdata.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessdata.isEmpty, sessdata.rangeOfCharacter(from: CharacterSet(charactersIn: ";\n\r")) == nil else {
            throw BiliCredentialKeychainError.invalidPayload
        }
        let biliJct = credential.biliJct?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBiliJct: String?
        if let biliJct, !biliJct.isEmpty, biliJct.rangeOfCharacter(from: CharacterSet(charactersIn: ";\n\r")) == nil {
            finalBiliJct = biliJct
        } else {
            finalBiliJct = nil
        }
        let dedeUserID = credential.dedeUserID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BiliCredential(
            sessdata: sessdata,
            biliJct: finalBiliJct,
            dedeUserID: dedeUserID?.isEmpty == true ? nil : dedeUserID,
            updatedAt: credential.updatedAt
        )
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func makeReadFailure(
        _ error: BiliCredentialKeychainError,
        logFailures: Bool
    ) -> BiliCredentialReadResult {
        if logFailures {
            logReadFailure(error)
        }
        return .failure(error)
    }

    private func logReadFailure(_ error: BiliCredentialKeychainError) {
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
