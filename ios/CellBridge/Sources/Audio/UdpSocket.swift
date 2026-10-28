import Darwin
import Foundation

/// One UDP socket bound to an ephemeral port, talking to a single peer. Created before the call is answered so
/// the port can be announced to the host; only packets from that peer are delivered.
final class UdpSocket: @unchecked Sendable {
    enum Failure: Error { case notIPv4(String), socket(Int32) }

    let port: UInt16
    private let fd: Int32
    private var peer: sockaddr_in
    private let state = NSLock()
    private var running = true
    private var receiving = false

    init(peerHost: String, peerPort: UInt16) throws {
        var peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = peerPort.bigEndian
        guard inet_pton(AF_INET, peerHost, &peer.sin_addr) == 1 else { throw Failure.notIPv4(peerHost) }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        var length = size
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.socket(code)
        }
        var voiceService = Int32(NET_SERVICE_TYPE_VO) // interactive voice: the Wi-Fi radio does not batch it with bulk traffic
        setsockopt(descriptor, SOL_SOCKET, SO_NET_SERVICE_TYPE, &voiceService, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000) // lets the receive loop notice close()
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        fd = descriptor
        port = UInt16(bigEndian: local.sin_port)
        self.peer = peer
    }

    func startReceiving(_ handler: @escaping (Data) -> Void) {
        state.lock()
        receiving = true
        state.unlock()
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while isRunning {
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                    }
                }
                guard count > 0, from.sin_addr.s_addr == peer.sin_addr.s_addr, from.sin_port == peer.sin_port else { continue }
                handler(Data(buffer[..<count]))
            }
            Darwin.close(fd) // closed here so the fd is never reused while this thread still reads it
        }
    }

    func send(_ data: Data) {
        guard isRunning else { return }
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        state.lock()
        let wasRunning = running
        running = false
        let hasReader = receiving
        state.unlock()
        if wasRunning && !hasReader { Darwin.close(fd) }
    }

    private var isRunning: Bool {
        state.lock()
        defer { state.unlock() }
        return running
    }
}
