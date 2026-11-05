package com.cellbridge.audio

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

const val DAEMON_PORT = 8766

/**
 * Speaks the daemon's loopback protocol (docs/protocol.md). The daemon serves one client and keeps the audio
 * running only while that connection is open, so a started relay holds its socket until [stop].
 *
 * If the daemon dies mid-call (init restarts it within seconds and it puts the phone microphone back), the socket
 * drops: the relay is started again for the same peer, every [retryEveryMs] for up to [retryWindowMs]. If that does
 * not work, [onLost] is called once so that whatever was held for the audio (call volume, Wi-Fi lock) is let go.
 * The daemon also sends the Telecom log lines about call tones on this connection; [onToneLine] gets them.
 */
class AudioDaemonClient(
    private val token: String,
    private val port: Int = DAEMON_PORT,
    private val timeoutMs: Int = 2_000,
    private val retryWindowMs: Long = 10_000,
    private val retryEveryMs: Long = 1_000,
    private val onLost: () -> Unit = {},
    private val onToneLine: (String) -> Unit = {},
) : CallAudio {
    private class Session(val socket: Socket) {
        val closing = AtomicBoolean(false)
        val stopAck = CompletableDeferred<Unit>()
    }

    private val lock = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var session: Session? = null
    /** The relay the app wants running; set while there is one, whether or not the daemon currently serves it. */
    private var wanted: InetSocketAddress? = null
    private var recovery: Job? = null

    override suspend fun isAvailable(): Boolean = lock.withLock {
        if (session != null) return true
        withContext(Dispatchers.IO) { runCatching { connect().use { true } }.getOrDefault(false) }
    }

    override suspend fun start(peer: InetSocketAddress): Boolean = lock.withLock {
        stopLocked()
        if (peer.address.address.size != 4) return false // the daemon streams over IPv4 only
        val ok = open(peer)
        if (ok) wanted = peer
        ok
    }

    override suspend fun stop() = lock.withLock { stopLocked() }

    private suspend fun stopLocked() {
        recovery?.cancel()
        recovery = null
        wanted = null
        val current = session ?: return
        session = null
        current.closing.set(true)
        withContext(Dispatchers.IO) {
            runCatching {
                current.socket.send(MSG_STOP, ByteArray(0))
                withTimeoutOrNull(timeoutMs.toLong()) { current.stopAck.await() }
            }
            current.socket.close() // closing also makes the daemon switch the routes off
        }
    }

    /** Connects and starts the relay for [peer]; false (nothing left open) if the daemon refuses or is unreachable. */
    private suspend fun open(peer: InetSocketAddress): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val socket = connect()
            try {
                val address = peer.address.address
                socket.send(MSG_START, byteArrayOf(START_DL_UL, *address, peer.port.toByte(), (peer.port shr 8).toByte()))
                check(socket.reply() == MSG_OK) { "daemon refused start" }
                socket.soTimeout = 0 // from here on a reader waits for the daemon to speak, or for the socket to drop
                val opened = Session(socket)
                session = opened
                scope.launch { watch(opened) }
                true
            } catch (e: Exception) {
                socket.close()
                throw e
            }
        }.getOrDefault(false)
    }

    /** Reads whatever the daemon sends (the reply to STOP, tone lines); returns when the socket is gone. */
    private suspend fun watch(s: Session) {
        val input = DataInputStream(s.socket.getInputStream())
        try {
            while (true) {
                val type = input.readUnsignedByte()
                val length = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
                val payload = ByteArray(length).also(input::readFully)
                if (type == MSG_TONE_LINE) runCatching { onToneLine(String(payload, Charsets.UTF_8)) } else s.stopAck.complete(Unit)
            }
        } catch (_: IOException) {
            // closed by us (stop) or by a dead daemon
        }
        if (!s.closing.get()) dropped(s)
    }

    private suspend fun dropped(s: Session) {
        lock.withLock {
            if (session !== s) return
            session = null
            runCatching { s.socket.close() }
            val target = wanted ?: return
            recovery = scope.launch { recover(target) }
        }
    }

    private suspend fun recover(target: InetSocketAddress) {
        val deadline = System.currentTimeMillis() + retryWindowMs
        while (scope.isActive && System.currentTimeMillis() < deadline) {
            delay(retryEveryMs)
            val done = lock.withLock {
                if (wanted !== target || session != null) return // stopped or replaced meanwhile
                open(target)
            }
            if (done) return
        }
        val lost = lock.withLock { (wanted === target && session == null).also { if (it) wanted = null } }
        if (lost) onLost()
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
        const val MSG_TONE_LINE = 0x90
        const val MSG_OK = 0x80
        const val START_DL_UL: Byte = 0x03
    }
}
