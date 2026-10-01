// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation

/// Exact Swift port of Navidrome `model/id.Encode`/`Decode` and Jellyfin `dto.EncodeID`.
/// This is a protocol-boundary codec, not an ID heuristic: only a valid canonical 22-character
/// base62 value is accepted. Legacy IDs stay opaque and must be resolved through aliases first.
nonisolated enum NavidromeJellyfinIDCodec {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let digitByByte = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })

    static func jellyfinGUID(fromCanonicalID value: String) -> String? {
        guard let bytes = decodeCanonical(value) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalID(fromJellyfinGUID value: String) -> String? {
        guard let bytes = decodeGUID(value), !isReserved(bytes) else { return nil }
        var quotient = bytes
        var encoded: [UInt8] = []
        while quotient.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in quotient.indices {
                let accumulator = remainder * 256 + Int(quotient[index])
                quotient[index] = UInt8(accumulator / 62)
                remainder = accumulator % 62
            }
            encoded.append(alphabet[remainder])
        }
        while encoded.count < 22 { encoded.append(alphabet[0]) }
        guard encoded.count == 22 else { return nil }
        return String(decoding: encoded.reversed(), as: UTF8.self)
    }

    static func playlistEntryID(fromJellyfinGUID value: String) -> String? {
        guard let bytes = decodeGUID(value), isReserved(bytes), bytes[12] == 3 else { return nil }
        let payload = Int(bytes[13]) << 16 | Int(bytes[14]) << 8 | Int(bytes[15])
        return String(payload)
    }

    private static func decodeCanonical(_ value: String) -> [UInt8]? {
        let input = Array(value.utf8)
        guard input.count == 22 else { return nil }
        var output = [UInt8](repeating: 0, count: 16)
        for byte in input {
            guard let digit = digitByByte[byte] else { return nil }
            var carry = digit
            for index in output.indices.reversed() {
                let accumulator = Int(output[index]) * 62 + carry
                output[index] = UInt8(accumulator & 0xff)
                carry = accumulator >> 8
            }
            guard carry == 0 else { return nil }
        }
        return output
    }

    private static func decodeGUID(_ value: String) -> [UInt8]? {
        let normalized = value.replacingOccurrences(of: "-", with: "").lowercased()
        guard normalized.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = normalized.startIndex
        for _ in 0..<16 {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func isReserved(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes.prefix(12).allSatisfy { $0 == 0 }
    }
}
