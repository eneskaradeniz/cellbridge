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
    val started = mutableListOf<InetSocketAddress>()
    var stops = 0
    override suspend fun isAvailable() = available
    override suspend fun start(peer: InetSocketAddress): Boolean = startResult.also { started += peer }
    override suspend fun stop() { stops++ }
}

class CallAudioBridgeTest {
    private class FakeFeed : CallFeed {
        val flow = MutableSharedFlow<CallEvent>(extraBufferCapacity = 8)
        override val events: SharedFlow<CallEvent> = flow
        override fun liveCalls() = emptyList<CallSnapshot>()
    }

    private val feed = FakeFeed()
    private val audio = FakeAudio()
    private val bridge = CallAudioBridge(feed, audio)
    private val job = Job()
    private val peer = InetSocketAddress(InetAddress.getByAddress(byteArrayOf(192.toByte(), 168.toByte(), 105, 2)), 40000)

    private fun call(status: CallStatus, id: String = "c1") = CallSnapshot(id, "+90555", CallDirection.INCOMING, status)

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
}
