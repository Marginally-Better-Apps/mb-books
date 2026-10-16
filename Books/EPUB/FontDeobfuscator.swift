import CryptoKit
import Foundation

/// Reverses IDPF and Adobe font obfuscation (EPUB 3.4 lists it as an outdated but conforming feature).
nonisolated enum FontDeobfuscator {
    static func deobfuscate(_ data: Data, algorithm: FontObfuscation, identifier: String) -> Data {
        let key: [UInt8]
        let length: Int
        switch algorithm {
        case .idpf:
            // SHA-1 of the unique identifier with XML whitespace removed; first 1040 bytes.
            // Filter scalars, not Characters: "\r\n" is a single Character in Swift.
            let whitespace: Set<UInt32> = [0x20, 0x09, 0x0D, 0x0A]
            let cleaned = String(String.UnicodeScalarView(identifier.unicodeScalars.filter { !whitespace.contains($0.value) }))
            key = Array(Insecure.SHA1.hash(data: Data(cleaned.utf8)))
            length = 1040
        case .adobe:
            // The 16 bytes of a UUID identifier; first 1024 bytes.
            let hex = identifier.lowercased()
                .replacingOccurrences(of: "urn:uuid:", with: "")
                .filter(\.isHexDigit)
            guard hex.count == 32 else { return data }
            key = stride(from: 0, to: 32, by: 2).compactMap { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
            }
            length = 1024
        }
        var bytes = [UInt8](data)
        for index in 0..<min(length, bytes.count) {
            bytes[index] ^= key[index % key.count]
        }
        return Data(bytes)
    }
}
