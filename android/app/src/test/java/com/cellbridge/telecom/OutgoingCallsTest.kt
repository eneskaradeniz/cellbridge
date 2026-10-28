package com.cellbridge.telecom

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class OutgoingCallsTest {
    private class Feed : CallFeed {
        val flow = MutableSharedFlow<CallEvent>(extraBufferCapacity = 8)
        var live: List<CallSnapshot> = emptyList()
        override val events: SharedFlow<CallEvent> = flow
        override fun liveCalls() = live
    }

    private class Telecom(private val feed: Feed) : TelecomPlacer {
        val placed = mutableListOf<String>()
        var emergency = setOf("112", "911")
        var dialingCallId: String? = "o1" // what Telecom reports after place(); null = never
        var failure: Exception? = null

        override fun isEmergency(number: String) = number in emergency
        override fun place(number: String) {
            failure?.let { throw it }
            placed += number
            dialingCallId?.let {
                feed.flow.tryEmit(CallEvent.Dialing(CallSnapshot(it, number, CallDirection.OUTGOING, CallStatus.DIALING)))
            }
        }
    }

    private val feed = Feed()
    private val telecom = Telecom(feed)
    private val calls = OutgoingCalls(feed, telecom).also { it.startTimeoutMs = 200 }

    @Test
    fun `a plain number is placed and the new call id is returned`() = runBlocking {
        assertEquals(DialOutcome.Placed("o1"), calls.dial("+905551112233"))
        assertEquals(listOf("+905551112233"), telecom.placed)
    }

    @Test
    fun `spaces, brackets and dashes are removed before dialing`() = runBlocking {
        calls.dial("+90 (555) 111-22 33")
        assertEquals(listOf("+905551112233"), telecom.placed)
    }

    @Test
    fun `anything but a plain number is refused, service codes included`() = runBlocking {
        for (bad in listOf("abc", "*#06#", "*21*5551112233#", "12", "", "+", "5551112233x", "1".repeat(21))) {
            assertEquals("for \"$bad\"", DialOutcome.Failed("invalid"), calls.dial(bad))
        }
        assertEquals(emptyList<String>(), telecom.placed)
    }

    @Test
    fun `emergency numbers are never dialed`() = runBlocking {
        assertEquals(DialOutcome.Failed("emergency"), calls.dial("112"))
        assertEquals(DialOutcome.Failed("emergency"), calls.dial("1 1 2"))
        assertEquals(emptyList<String>(), telecom.placed)
    }

    @Test
    fun `a second outgoing call is refused while one is in progress`() = runBlocking {
        feed.live = listOf(CallSnapshot("o0", "+905550000000", CallDirection.OUTGOING, CallStatus.ACTIVE))
        assertEquals(DialOutcome.Failed("busy"), calls.dial("+905551112233"))
        assertEquals(emptyList<String>(), telecom.placed)
    }

    @Test
    fun `an incoming call does not block dialing`() = runBlocking {
        feed.live = listOf(CallSnapshot("i1", "+905550000000", CallDirection.INCOMING, CallStatus.RINGING))
        assertEquals(DialOutcome.Placed("o1"), calls.dial("+905551112233"))
    }

    @Test
    fun `a call Telecom never starts fails instead of hanging`() = runBlocking {
        telecom.dialingCallId = null
        assertEquals(DialOutcome.Failed("failed"), calls.dial("+905551112233"))
    }

    @Test
    fun `a platform refusal is reported as failed`() = runBlocking {
        telecom.failure = SecurityException("no CALL_PHONE")
        assertEquals(DialOutcome.Failed("failed"), calls.dial("+905551112233"))
    }
}
