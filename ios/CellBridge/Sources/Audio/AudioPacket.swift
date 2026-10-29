import Foundation

/// UDP audio packet (docs/protocol.md): u16 seq, u8 flags, u8 reserved (little endian) + one 20 ms frame of 16 kHz mono S16.
/// With flag bit 0 the frame before it follows, so a single lost packet is repaired by the next one.
enum AudioPacket {
    static let samplesPerFrame = 320
    static let headerBytes = 4
    static let frameBytes = samplesPerFrame * 2
    static let size = headerBytes + frameBytes
    private static let previousFrameFlag: UInt8 = 1

    static func encode(seq: UInt16, pcm: [Int16], previous: [Int16]? = nil) -> Data {
        precondition(pcm.count == samplesPerFrame && (previous?.count ?? samplesPerFrame) == samplesPerFrame)
        var data = Data(capacity: size + frameBytes)
        data.append(contentsOf: [UInt8(seq & 0xff), UInt8(seq >> 8), previous == nil ? 0 : previousFrameFlag, 0])
        pcm.withUnsafeBytes { data.append(contentsOf: $0) } // arm64 is little endian, like the wire format
        previous?.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Nil unless the packet is one whole frame, or a frame plus the flagged previous one.
    static func decode(_ data: Data) -> (seq: UInt16, pcm: [Int16], previous: [Int16]?)? {
        let withPrevious = data.count == size + frameBytes
        guard data.count == size || withPrevious else { return nil }
        let bytes = [UInt8](data)
        if withPrevious && bytes[2] & previousFrameFlag == 0 { return nil }
        let seq = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var pcm = [Int16](repeating: 0, count: samplesPerFrame)
        pcm.withUnsafeMutableBytes { $0.copyBytes(from: bytes[headerBytes..<size]) }
        guard withPrevious else { return (seq, pcm, nil) }
        var previous = [Int16](repeating: 0, count: samplesPerFrame)
        previous.withUnsafeMutableBytes { $0.copyBytes(from: bytes[size...]) }
        return (seq, pcm, previous)
    }
}
