import Foundation

/// One application frame per WebSocket frame, with authenticated kind, flags
/// and total length repeated inside each Noise chunk. A framing failure must
/// close the channel. Previously authenticated chunks have consumed nonces.
final class ProtectedRecordCodec {
    private static let headerBytes = 6
    private static let chunkOverhead = 2 + headerBytes + NoiseCipherState.tagBytes
    static let maxChunkDataBytes = NoiseCipherState.maxMessageBytes - headerBytes - NoiseCipherState.tagBytes

    private static let firstFlag: UInt8 = 1
    private static let finalFlag: UInt8 = 2

    private enum Kind: UInt8 {
        case text = 0
        case binary = 1
    }

    private var sender: NoiseCipherState
    private var receiver: NoiseCipherState
    let binaryCiphertext: Bool

    init(sender: NoiseCipherState, receiver: NoiseCipherState, binaryCiphertext: Bool) {
        self.sender = sender
        self.receiver = receiver
        self.binaryCiphertext = binaryCiphertext
    }

    func seal(_ frame: TransportFrame) throws -> TransportFrame {
        let kind: Kind
        let bytes: [UInt8]
        switch frame {
        case .text(let text):
            kind = .text
            bytes = Array(text.utf8)
        case .binary(let data):
            kind = .binary
            bytes = data
        }
        guard let totalLength = UInt32(exactly: bytes.count) else {
            throw NoiseProtocolError("Protected frame too large")
        }

        let chunks = Self.chunkCount(bytes.count)
        var wire = [UInt8]()
        wire.reserveCapacity(bytes.count + chunks * Self.chunkOverhead)
        let lengthBytes = withUnsafeBytes(of: totalLength.bigEndian) { Array($0) }
        var offset = 0
        for index in 0..<chunks {
            let end = offset + min(Self.maxChunkDataBytes, bytes.count - offset)
            var flags: UInt8 = 0
            if index == 0 { flags |= Self.firstFlag }
            if index == chunks - 1 { flags |= Self.finalFlag }
            var plaintext = [kind.rawValue, flags] + lengthBytes
            plaintext.append(contentsOf: bytes[offset..<end])
            let ciphertext = try sender.seal(plaintext)
            wire.append(UInt8(ciphertext.count >> 8))
            wire.append(UInt8(truncatingIfNeeded: ciphertext.count))
            wire.append(contentsOf: ciphertext)
            offset = end
        }
        if binaryCiphertext && kind == .binary { return .binary(wire) }
        return .text(Data(wire).base64EncodedString())
    }

    func open(_ frame: TransportFrame) throws -> TransportFrame {
        let wire: [UInt8]
        switch frame {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = ConnectionOffer.decodeBase64URL(trimmed) else {
                throw NoiseProtocolError("Invalid protected record base64")
            }
            wire = Array(data)
        case .binary(let bytes):
            wire = bytes
        }
        guard !wire.isEmpty else { throw NoiseProtocolError("Empty protected record") }

        var offset = 0
        var chunk = try readChunk(wire, offset: &offset)
        let chunks = Self.chunkCount(chunk.totalLength)
        // The authenticated length cannot drive allocation until the record's
        // exact size agrees with it. Frame lengths are uint32 on a 64-bit target.
        guard chunk.totalLength + chunks * Self.chunkOverhead == wire.count else {
            throw NoiseProtocolError("Protected record length mismatch")
        }
        let kind = chunk.kind
        let totalLength = chunk.totalLength
        var plaintext = [UInt8]()
        plaintext.reserveCapacity(totalLength)
        for index in 0..<chunks {
            if index > 0 { chunk = try readChunk(wire, offset: &offset) }
            guard chunk.kind == kind, chunk.totalLength == totalLength else {
                throw NoiseProtocolError("Protected chunk metadata changed")
            }
            let expectedSize = min(Self.maxChunkDataBytes, totalLength - plaintext.count)
            guard chunk.data.count == expectedSize else {
                throw NoiseProtocolError("Incorrect protected chunk size")
            }
            let first = index == 0
            let final = index == chunks - 1
            guard chunk.isFirst == first, chunk.isFinal == final else {
                throw NoiseProtocolError("Incorrect protected chunk flags")
            }
            plaintext.append(contentsOf: chunk.data)
        }
        guard offset == wire.count else { throw NoiseProtocolError("Trailing protected record data") }

        if kind == .binary { return .binary(plaintext) }
        // Match the upstream fatal UTF-8 decoder, including its leading BOM handling.
        let utf8 = plaintext.starts(with: [0xef, 0xbb, 0xbf]) ? plaintext.dropFirst(3) : plaintext[...]
        guard let text = String(bytes: utf8, encoding: .utf8) else {
            throw NoiseProtocolError("Invalid protected record UTF-8")
        }
        return .text(text)
    }

    private struct Chunk {
        let kind: Kind
        let isFirst: Bool
        let isFinal: Bool
        let totalLength: Int
        let data: ArraySlice<UInt8>
    }

    private func readChunk(_ wire: [UInt8], offset: inout Int) throws -> Chunk {
        guard wire.count - offset >= 2 else { throw NoiseProtocolError("Truncated protected record") }
        let ciphertextLength = Int(wire[offset]) << 8 | Int(wire[offset + 1])
        let start = offset + 2
        guard ciphertextLength >= Self.headerBytes + NoiseCipherState.tagBytes else {
            throw NoiseProtocolError("Invalid protected chunk length")
        }
        guard ciphertextLength <= wire.count - start else {
            throw NoiseProtocolError("Truncated protected chunk")
        }
        let end = start + ciphertextLength
        let plaintext = try receiver.open(wire[start..<end])
        offset = end
        guard let kind = Kind(rawValue: plaintext[0]) else {
            throw NoiseProtocolError("Invalid protected frame kind")
        }
        let flags = plaintext[1]
        guard flags & ~(Self.firstFlag | Self.finalFlag) == 0 else {
            throw NoiseProtocolError("Reserved protected chunk flag set")
        }
        let totalLength = plaintext[2..<Self.headerBytes].reduce(0) { ($0 << 8) | Int($1) }
        return Chunk(
            kind: kind,
            isFirst: flags & Self.firstFlag != 0,
            isFinal: flags & Self.finalFlag != 0,
            totalLength: totalLength,
            data: plaintext.dropFirst(Self.headerBytes)
        )
    }

    private static func chunkCount(_ bytes: Int) -> Int {
        max(1, (bytes + maxChunkDataBytes - 1) / maxChunkDataBytes)
    }
}
