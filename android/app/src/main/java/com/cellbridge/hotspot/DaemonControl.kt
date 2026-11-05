package com.cellbridge.hotspot

import com.cellbridge.audio.DAEMON_PORT
import com.cellbridge.sms.SentSmsWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket

/** The Wi-Fi networks the phone knows: the one it is connected to (if any) and every saved one. */
data class WifiNetworks(val connected: String?, val saved: Set<String>) {
    /** At home means connected to a network saved on the phone (the phone only joins saved networks by itself). */
    val atHome get() = connected != null && connected in saved
}

/** What the root daemon can do about Wi-Fi (docs/protocol.md, "Hotspot"). */
interface WifiDaemon {
    /** Null when the daemon cannot be reached (it serves one client at a time, so a running call relay also blocks it). */
    suspend fun networks(): WifiNetworks?
    suspend fun hotspot(on: Boolean): Boolean
}

fun parseNetworks(text: String): WifiNetworks {
    val lines = text.split('\n')
    return WifiNetworks(lines.firstOrNull()?.ifEmpty { null }, lines.drop(1).filter { it.isNotEmpty() }.toSet())
}

/** The root daemon's one-shot requests (Wi-Fi, filing sent texts), one short connection each: the long-lived one belongs to the call audio. */
class DaemonControl(private val token: String, private val port: Int = DAEMON_PORT) : WifiDaemon, SentSmsWriter {
    override suspend fun networks(): WifiNetworks? =
        request(MSG_WIFI, ByteArray(0), 8_000)?.takeIf { it.first == MSG_WIFI_INFO }?.let { parseNetworks(String(it.second, Charsets.UTF_8)) }

    // Switching the hotspot on takes the daemon about six seconds.
    override suspend fun hotspot(on: Boolean): Boolean =
        request(MSG_HOTSPOT, byteArrayOf(if (on) 1 else 0), 30_000)?.first == MSG_OK

    override suspend fun write(to: String, body: String, timestamp: Long): Boolean {
        val text = (to + "\n" + body).toByteArray(Charsets.UTF_8)
        val date = ByteArray(8) { (timestamp shr (8 * it)).toByte() }
        val full = date + text
        // One frame holds 4096 bytes. A longer text is cut on a character boundary rather than not filed at all.
        var end = minOf(full.size, MAX_PAYLOAD)
        while (end < full.size && end > date.size && (full[end].toInt() and 0xC0) == 0x80) end--
        return request(MSG_SAVE_SENT, full.copyOf(end), 15_000)?.first == MSG_OK
    }

    private suspend fun request(type: Int, payload: ByteArray, replyTimeoutMs: Int): Pair<Int, ByteArray>? = withContext(Dispatchers.IO) {
        runCatching {
            Socket().use { socket ->
                socket.tcpNoDelay = true
                socket.soTimeout = AUTH_TIMEOUT_MS
                socket.connect(InetSocketAddress("127.0.0.1", port), AUTH_TIMEOUT_MS)
                socket.send(MSG_AUTH, token.toByteArray())
                val input = DataInputStream(socket.getInputStream())
                if (input.reply().first != MSG_OK) return@runCatching null
                socket.soTimeout = replyTimeoutMs
                socket.send(type, payload)
                input.reply()
            }
        }.getOrNull()
    }

    private fun Socket.send(type: Int, payload: ByteArray) {
        getOutputStream().apply { write(byteArrayOf(type.toByte(), payload.size.toByte(), (payload.size shr 8).toByte()) + payload); flush() }
    }

    private fun DataInputStream.reply(): Pair<Int, ByteArray> {
        val type = readUnsignedByte()
        val length = readUnsignedByte() or (readUnsignedByte() shl 8)
        return type to ByteArray(length).also(::readFully)
    }

    private companion object {
        const val AUTH_TIMEOUT_MS = 2_000
        const val MSG_AUTH = 0x00
        const val MSG_HOTSPOT = 0x03
        const val MSG_WIFI = 0x04
        const val MSG_SAVE_SENT = 0x05
        const val MAX_PAYLOAD = 4096
        const val MSG_OK = 0x80
        const val MSG_WIFI_INFO = 0x82
    }
}
