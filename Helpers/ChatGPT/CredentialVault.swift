import CryptoKit
import Foundation
import Security

// This trusted utility keeps the encryption key in the login Keychain. Secret
// input/output travels only through anonymous pipes to the Node helper.
enum VaultError: Error { case unavailable, invalidInput }

func loadKey(create: Bool) throws -> SymmetricKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.vaydeaos.chatgpt.vault",
        kSecAttrAccount as String: "aes256gcm-v1",
        kSecUseDataProtectionKeychain as String: false
    ]
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
    guard status == errSecItemNotFound, create else { throw VaultError.unavailable }
    let key = SymmetricKey(size: .bits256)
    var addition = query
    addition[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(addition as CFDictionary, nil)
    if added == errSecDuplicateItem { return try loadKey(create: false) }
    guard added == errSecSuccess else { throw VaultError.unavailable }
    return key
}

do {
    let mode = CommandLine.arguments.dropFirst().first
    guard mode == "encrypt" || mode == "decrypt" else { throw VaultError.invalidInput }
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        input.append(chunk)
        guard input.count <= 8 * 1024 * 1024 else { throw VaultError.invalidInput }
    }
    let key = try loadKey(create: mode == "encrypt")
    let output: Data
    if mode == "encrypt" {
        guard let combined = try AES.GCM.seal(input, using: key).combined else { throw VaultError.invalidInput }
        output = combined
    } else {
        output = try AES.GCM.open(AES.GCM.SealedBox(combined: input), using: key)
    }
    try FileHandle.standardOutput.write(contentsOf: output)
} catch {
    // No provider error, key, or credential text reaches logs.
    exit(1)
}
