package com.cellbridge.audio

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

const val DAEMON_PORT = 8766

/**
 * Speaks the daemon's loopback protocol (docs/protocol.md). The daemon serves one client and keeps the audio
 * running only while that connection is open, so a started relay holds its socket until [stop].
 */
class AudioDaemonClient(
    private val token: String,
    private val port: Int = DAEMON_PORT,
    private val timeoutMs: Int = 2_000,
) : CallAudio {
    private val lock = Mutex()
    private var session: Socket? = null

    override suspend fun isAvailable(): Boolean = lock.withLock {
        if (session != null) return true
        withContext(Dispatchers.IO) { runCatching { connect().use { true } }.getOrDefault(false) }
    }

    override suspend fun start(peer: InetSocketAddress): Boolean = lock.withLock {
        closeSession()
        val address = peer.address.address
        if (address.size != 4) return false // the daemon streams over IPv4 only
        withContext(Dispatchers.IO) {
            runCatching {
                val socket = connect()
                try {
                    val payload = byteArrayOf(START_DL_UL, *address, peer.port.toByte(), (peer.port shr 8).toByte())
                    socket.send(MSG_START, payload)
                    check(socket.reply() == MSG_OK) { "daemon refused start" }
                    session = socket
                    true
                } catch (e: Exception) {
                    socket.close()
                    throw e
                }
            }.getOrDefault(false)
        }
    }

    override suspend fun stop() = lock.withLock { closeSession() }

    private suspend fun closeSession() {
        val socket = session ?: return
        session = null
        withContext(Dispatchers.IO) {
            runCatching { socket.send(MSG_STOP, ByteArray(0)); socket.reply() }
            socket.close() // closing also makes the daemon switch the routes off
        }
    }

    /** Connected and authenticated, or throws. */
    private fun connect(): Socket {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = timeoutMs
            socket.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
            socket.send(MSG_AUTH, token.toByteArray())
            if (socket.reply() != MSG_OK) throw IOException("daemon rejected the token")
            return socket
        } catch (e: Exception) {
            socket.close()
            throw e
        }
    }

    private fun Socket.send(type: Int, payload: ByteArray) {
        val frame = byteArrayOf(type.toByte(), payload.size.toByte(), (payload.size shr 8).toByte(), *payload)
        getOutputStream().apply { write(frame); flush() }
    }

    /** Type of the next reply; the payload (a reason on ERR) is not needed. */
    private fun Socket.reply(): Int {
        val input = DataInputStream(getInputStream())
        val type = input.readUnsignedByte()
        val length = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
        input.skipBytes(length)
        return type
    }

    private companion object {
        const val MSG_AUTH = 0x00
        const val MSG_START = 0x01
        const val MSG_STOP = 0x02
        const val MSG_OK = 0x80
        const val START_DL_UL: Byte = 0x03
    }
}
