package com.cellbridge.audio

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress

class FakeAudio(var available: Boolean = true, var startResult: Boolean = true) : CallAudio {
    val started = java.util.concurrent.CopyOnWriteArrayList<InetSocketAddress>()
    @Volatile var stops = 0
    override suspend fun isAvailable() = available
    override suspend fun start(peer: InetSocketAddress): Boolean = startResult.also { started += peer }
    override suspend fun stop() { stops++ }
}

class CallAudioBridgeTest {
    private class FakeFeed : CallFeed {
        val flow = MutableSharedFlow<CallEvent>(extraBufferCapacity = 8)
        override val events: SharedFlow<CallEvent> = flow
        var live = emptyList<CallSnapshot>()
        override fun liveCalls() = live
    }

    private val feed = FakeFeed()
    private val audio = FakeAudio()
    private val bridge = CallAudioBridge(feed, audio).also { it.stopGraceMs = 0 }
    private val job = Job()
    private val peer = InetSocketAddress(InetAddress.getByAddress(byteArrayOf(192.toByte(), 168.toByte(), 105, 2)), 40000)

    private fun call(status: CallStatus, id: String = "c1") = CallSnapshot(id, "+90555", CallDirection.INCOMING, status)
    private fun outgoing(status: CallStatus, id: String = "c1") = CallSnapshot(id, "+90555", CallDirection.OUTGOING, status)

    @Before fun setUp() = bridge.start(CoroutineScope(Dispatchers.Unconfined + job))

    @After fun tearDown() = job.cancel()

    @Test
    fun `audio starts when the expected call is answered and stops when it ends`() = runBlocking {
        bridge.expect("c1", peer)
        feed.flow.emit(CallEvent.Ringing(call(CallStatus.RINGING)))
        assertEquals(emptyList<InetSocketAddress>(), audio.started)

        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        assertEquals(listOf(peer), audio.started)

        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED), reason = null))
        assertEquals(1, audio.stops)
    }

    @Test
    fun `a call without an announced peer stays control-only`() = runBlocking {
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED), reason = null))
        assertEquals(emptyList<InetSocketAddress>(), audio.started)
        assertEquals(0, audio.stops)
    }

    @Test
    fun `another call ending does not stop the running audio`() = runBlocking {
        bridge.expect("c1", peer)
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED, id = "other"), reason = null))
        assertEquals(0, audio.stops)
    }

    @Test
    fun `a call rejected before it was answered releases its peer without touching the daemon`() = runBlocking {
        bridge.expect("c1", peer)
        bridge.forget("c1")
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        assertEquals(emptyList<InetSocketAddress>(), audio.started)
    }

    @Test
    fun `a daemon that refuses to start does not break later events`() = runBlocking {
        audio.startResult = false
        bridge.expect("c1", peer)
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED), reason = null))
        assertEquals(1, audio.stops) // stop is idempotent on the daemon side
    }

    @Test
    fun `release stops the relay and forgets the peer`() = runBlocking {
        bridge.expect("c1", peer)
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        assertEquals(setOf("c1"), bridge.bridged.value)

        assertEquals(true, bridge.release("c1"))
        assertEquals(1, audio.stops)
        assertEquals(emptySet<String>(), bridge.bridged.value)
        assertEquals(false, bridge.release("c1")) // nothing left to release
    }

    @Test
    fun `attach starts the relay for a call that is already active`() = runBlocking {
        feed.live = listOf(call(CallStatus.ACTIVE))
        assertEquals(true, bridge.attach("c1", peer))
        assertEquals(listOf(peer), audio.started)
        assertEquals(setOf("c1"), bridge.bridged.value)

        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED), reason = null))
        assertEquals(1, audio.stops)
        assertEquals(emptySet<String>(), bridge.bridged.value)
    }

    @Test
    fun `attach refuses a call that is not active or when the daemon will not start`() = runBlocking {
        feed.live = listOf(call(CallStatus.RINGING))
        assertEquals(false, bridge.attach("c1", peer))
        assertEquals(emptyList<InetSocketAddress>(), audio.started)

        feed.live = listOf(call(CallStatus.ACTIVE))
        audio.startResult = false
        assertEquals(false, bridge.attach("c1", peer))
        assertEquals(emptySet<String>(), bridge.bridged.value)
    }

    @Test
    fun `an outgoing call is relayed while it dials, so ringback and busy tones reach the client, and the answer does not restart it`() = runBlocking {
        bridge.expect("c1", peer)
        feed.flow.emit(CallEvent.Dialing(outgoing(CallStatus.DIALING)))
        assertEquals(listOf(peer), audio.started)
        assertEquals(setOf("c1"), bridge.bridged.value)

        feed.flow.emit(CallEvent.Answered(outgoing(CallStatus.ACTIVE)))
        assertEquals(listOf(peer), audio.started) // still the one start
        assertEquals(0, audio.stops)

        feed.flow.emit(CallEvent.Ended(outgoing(CallStatus.DISCONNECTED), reason = null))
        assertEquals(1, audio.stops)
    }

    @Test
    fun `a peer registered after the call began dialing starts the relay at once`() = runBlocking {
        feed.live = listOf(outgoing(CallStatus.DIALING))
        bridge.expect("c1", peer)
        assertEquals(listOf(peer), audio.started)
    }

    @Test
    fun `an incoming call still waits for the answer`() = runBlocking {
        feed.live = listOf(call(CallStatus.RINGING))
        bridge.expect("c1", peer)
        assertEquals(emptyList<InetSocketAddress>(), audio.started)
    }

    /** The bridge handles events on another thread: wait for what is expected instead of sleeping a fixed time and hoping. */
    private suspend fun eventually(what: String, check: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!check()) {
            check(System.currentTimeMillis() < deadline) { "timed out waiting for $what" }
            kotlinx.coroutines.delay(5)
        }
    }

    @Test
    fun `the relay stays up for the grace after the call ended, and a new relay is not cut by the old stop`() = runBlocking {
        val graced = CallAudioBridge(feed, audio).also { it.stopGraceMs = 300 }
        graced.start(CoroutineScope(Dispatchers.Default + job))
        // The bridge subscribes on another thread, and an event emitted before it does is lost (the shared flow has no replay).
        eventually("the bridge to subscribe") { feed.flow.subscriptionCount.value >= 2 } // the one from setUp and this one
        graced.expect("c1", peer)
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE)))
        eventually("the relay to start") { audio.started.size == 1 }
        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED), reason = null))
        assertEquals(0, audio.stops) // the end-of-call beep is still on its way
        eventually("the relay to stop after the grace") { audio.stops == 1 }

        graced.expect("c2", peer)
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE, id = "c2")))
        eventually("c2's relay to start") { audio.started.size == 2 }
        feed.flow.emit(CallEvent.Ended(call(CallStatus.DISCONNECTED, id = "c2"), reason = null))
        graced.expect("c3", peer) // a new call starts inside the grace
        feed.flow.emit(CallEvent.Answered(call(CallStatus.ACTIVE, id = "c3")))
        eventually("c3's relay to start") { audio.started.size == 3 }
        kotlinx.coroutines.delay(600) // twice the grace: c2's stop would have fired by now
        assertEquals(1, audio.stops) // c2's late stop did not take c3's relay with it
    }
}
