import Foundation

/// UDP audio packet (docs/protocol.md): u16 seq, u16 reserved (little endian) + one 20 ms frame of 16 kHz mono S16.
enum AudioPacket {
    static let samplesPerFrame = 320
    static let headerBytes = 4
    static let size = headerBytes + samplesPerFrame * 2

    static func encode(seq: UInt16, pcm: [Int16]) -> Data {
        precondition(pcm.count == samplesPerFrame)
        var data = Data(capacity: size)
        data.append(contentsOf: [UInt8(seq & 0xff), UInt8(seq >> 8), 0, 0])
        pcm.withUnsafeBytes { data.append(contentsOf: $0) } // arm64 is little endian, like the wire format
        return data
    }

    /// Nil unless the packet is exactly one whole frame.
    static func decode(_ data: Data) -> (seq: UInt16, pcm: [Int16])? {
        guard data.count == size else { return nil }
        let bytes = [UInt8](data)
        let seq = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        pcm.withUnsafeMutableBytes { $0.copyBytes(from: bytes[headerBytes...]) }
        return (seq, pcm)
    }
}
