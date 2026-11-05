package com.cellbridge.audio

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout
import java.io.DataInputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** A stand-in for cellbridge_audiod that speaks just enough of the loopback protocol. */
private class FakeDaemon(private val token: String, @Volatile var startReply: Int = 0x80) : AutoCloseable {
    val server = ServerSocket(0, 5, InetAddress.getByName("127.0.0.1"))
    val port get() = server.localPort
    val frames = CopyOnWriteArrayList<Pair<Int, List<Byte>>>()
    @Volatile var connections = 0
    private val sockets = CopyOnWriteArrayList<java.net.Socket>()

    /** Like a daemon that died: every open connection is cut. */
    fun dropAll() = sockets.forEach { runCatching { it.close() } }

    private val acceptor = thread(isDaemon = true) {
        while (!server.isClosed) {
            val socket = runCatching { server.accept() }.getOrNull() ?: break
            connections++
            sockets += socket
            thread(isDaemon = true) { serve(socket) }
        }
    }

    private fun serve(socket: java.net.Socket) = socket.use {
        val input = DataInputStream(it.getInputStream())
        runCatching {
            while (true) {
                val type = input.readUnsignedByte()
                val length = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
                val payload = ByteArray(length).also(input::readFully)
                frames += type to payload.toList()
                val reply = when (type) {
                    0x00 -> if (String(payload) == token) 0x80 else 0x81
                    0x01 -> startReply
                    else -> 0x80
                }
                it.getOutputStream().apply { write(byteArrayOf(reply.toByte(), 0, 0)); flush() }
            }
        }
    }

    override fun close() = server.close()
}

class AudioDaemonClientTest {
    @get:Rule val timeout: Timeout = Timeout(30, TimeUnit.SECONDS)

    private val daemons = mutableListOf<FakeDaemon>()
    private fun daemon(token: String = "TOKEN", startReply: Int = 0x80) = FakeDaemon(token, startReply).also { daemons += it }
    private fun peer(port: Int = 40000) =
        InetSocketAddress(InetAddress.getByAddress(byteArrayOf(192.toByte(), 168.toByte(), 105, 2)), port)

    @After fun tearDown() = daemons.forEach(FakeDaemon::close)

    @Test
    fun `available with the right token, unavailable with a wrong one or no daemon`() = runBlocking {
        val good = daemon()
        assertTrue(AudioDaemonClient("TOKEN", good.port).isAvailable())
        assertFalse(AudioDaemonClient("WRONG", good.port).isAvailable())

        val closedPort = ServerSocket(0).use { it.localPort }
        assertFalse(AudioDaemonClient("TOKEN", closedPort).isAvailable())
    }

    @Test
    fun `start sends flags, ipv4 and little endian port, stop sends STOP`() = runBlocking {
        val daemon = daemon()
        val client = AudioDaemonClient("TOKEN", daemon.port)

        assertTrue(client.start(peer(port = 0x1234)))
        val start = daemon.frames.last { it.first == 0x01 }.second
        assertArrayEquals(byteArrayOf(3, 192.toByte(), 168.toByte(), 105, 2, 0x34, 0x12), start.toByteArray())

        client.stop()
        assertEquals(0x02, daemon.frames.last().first)
    }

    @Test
    fun `isAvailable while a relay runs does not open another connection`() = runBlocking {
        val daemon = daemon()
        val client = AudioDaemonClient("TOKEN", daemon.port)
        client.start(peer())
        val before = daemon.connections
        assertTrue(client.isAvailable())
        assertEquals(before, daemon.connections)
        client.stop()
    }

    @Test
    fun `start fails cleanly when the daemon answers with an error`() = runBlocking {
        val daemon = daemon(startReply = 0x81)
        assertFalse(AudioDaemonClient("TOKEN", daemon.port).start(peer()))
    }

    @Test
    fun `start refuses a peer that is not ipv4`() = runBlocking {
        val daemon = daemon()
        val v6 = InetSocketAddress(InetAddress.getByName("::1"), 40000)
        assertFalse(AudioDaemonClient("TOKEN", daemon.port).start(v6))
        assertEquals(0, daemon.connections)
    }

    @Test
    fun `stop without a running relay is harmless`() = runBlocking {
        AudioDaemonClient("TOKEN", daemon().port).stop()
    }

    private fun fast(daemon: FakeDaemon, onLost: () -> Unit = {}) =
        AudioDaemonClient("TOKEN", daemon.port, timeoutMs = 500, retryWindowMs = 1_500, retryEveryMs = 50, onLost = onLost)

    private fun awaitTrue(what: String, condition: () -> Boolean) {
        val until = System.currentTimeMillis() + 10_000
        while (!condition()) {
            check(System.currentTimeMillis() < until) { "timed out waiting for: $what" }
            Thread.sleep(20)
        }
    }

    @Test
    fun `when the daemon drops the connection the relay is started again for the same peer`() = runBlocking {
        val daemon = daemon()
        val lost = java.util.concurrent.atomic.AtomicInteger()
        val client = fast(daemon) { lost.incrementAndGet() }
        assertTrue(client.start(peer(port = 0x1234)))
        val startsBefore = daemon.frames.count { it.first == 0x01 }

        daemon.dropAll()
        awaitTrue("a second START") { daemon.frames.count { it.first == 0x01 } == startsBefore + 1 }
        assertArrayEquals(byteArrayOf(3, 192.toByte(), 168.toByte(), 105, 2, 0x34, 0x12), daemon.frames.last { it.first == 0x01 }.second.toByteArray())
        assertEquals(0, lost.get())
        client.stop()
    }

    @Test
    fun `a daemon that needs a few tries is retried until it answers`() = runBlocking {
        val daemon = daemon()
        val client = fast(daemon)
        client.start(peer())
        daemon.startReply = 0x81 // restarting: refuses
        daemon.dropAll()
        Thread.sleep(300)
        daemon.startReply = 0x80
        val before = daemon.frames.count { it.first == 0x01 }
        awaitTrue("a START that is accepted") { daemon.frames.count { it.first == 0x01 } > before }
        client.stop()
    }

    @Test
    fun `when the daemon does not come back onLost is called once`() = runBlocking {
        val daemon = daemon()
        val lost = java.util.concurrent.atomic.AtomicInteger()
        val client = fast(daemon) { lost.incrementAndGet() }
        client.start(peer())
        daemon.startReply = 0x81
        daemon.dropAll()
        awaitTrue("onLost") { lost.get() == 1 }
        Thread.sleep(300)
        assertEquals(1, lost.get())
    }

    @Test
    fun `stop while recovering ends the retries without onLost`() = runBlocking {
        val daemon = daemon()
        val lost = java.util.concurrent.atomic.AtomicInteger()
        val client = fast(daemon) { lost.incrementAndGet() }
        client.start(peer())
        daemon.startReply = 0x81
        daemon.dropAll()
        Thread.sleep(150)
        client.stop()
        val connections = daemon.connections
        Thread.sleep(400)
        assertEquals(connections, daemon.connections)
        assertEquals(0, lost.get())
    }

    @Test
    fun `a normal stop is not mistaken for a lost daemon`() = runBlocking {
        val daemon = daemon()
        val lost = java.util.concurrent.atomic.AtomicInteger()
        val client = fast(daemon) { lost.incrementAndGet() }
        client.start(peer())
        client.stop()
        val connections = daemon.connections
        Thread.sleep(400)
        assertEquals(connections, daemon.connections)
        assertEquals(0, lost.get())
    }
}
