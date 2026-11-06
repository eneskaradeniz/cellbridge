package com.cellbridge.domain.logic

import com.cellbridge.domain.model.CallDirection.INCOMING
import com.cellbridge.domain.model.CallDirection.OUTGOING
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.domain.model.CallStatus.ACTIVE
import com.cellbridge.domain.model.CallStatus.DIALING
import com.cellbridge.domain.model.CallStatus.DISCONNECTED
import com.cellbridge.domain.model.CallStatus.HOLDING
import com.cellbridge.domain.model.CallStatus.RINGING
import com.cellbridge.domain.model.EndReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallTrackerTest {
    private val tracker = CallTracker()

    private fun incoming(status: CallStatus, id: String = "a") = CallSnapshot(id, "+905551112233", INCOMING, status)
    private fun outgoing(status: CallStatus, id: String = "o") = CallSnapshot(id, "+905551112233", OUTGOING, status)

    @Test
    fun `incoming call that is answered and hung up is not missed`() {
        assertEquals(CallEvent.Ringing(incoming(RINGING)), tracker.onUpdate(incoming(RINGING)))
        assertEquals(CallEvent.Answered(incoming(ACTIVE)), tracker.onUpdate(incoming(ACTIVE)))
        assertEquals(CallEvent.Ended(incoming(DISCONNECTED), reason = null), tracker.onUpdate(incoming(DISCONNECTED)))
    }

    @Test
    fun `incoming call that never became active is missed`() {
        tracker.onUpdate(incoming(RINGING))
        assertEquals(CallEvent.Ended(incoming(DISCONNECTED), reason = EndReason.MISSED), tracker.onUpdate(incoming(DISCONNECTED)))
    }

    @Test
    fun `incoming call declined by this side is rejected, not missed`() {
        tracker.onUpdate(incoming(RINGING))
        assertEquals(
            CallEvent.Ended(incoming(DISCONNECTED).copy(rejected = true), reason = EndReason.REJECTED),
            tracker.onUpdate(incoming(DISCONNECTED).copy(rejected = true)),
        )
    }

    @Test
    fun `outgoing call ending unanswered is never reported as missed`() {
        assertEquals(CallEvent.Dialing(outgoing(DIALING)), tracker.onUpdate(outgoing(DIALING)))
        assertEquals(CallEvent.Ended(outgoing(DISCONNECTED), reason = null), tracker.onUpdate(outgoing(DISCONNECTED)))
    }

    @Test
    fun `repeated status produces no event`() {
        tracker.onUpdate(incoming(RINGING))
        assertNull(tracker.onUpdate(incoming(RINGING)))
    }

    @Test
    fun `hold and resume after answering are reported as changes, not as a second answer`() {
        tracker.onUpdate(incoming(RINGING))
        tracker.onUpdate(incoming(ACTIVE))
        assertEquals(CallEvent.Changed(incoming(HOLDING)), tracker.onUpdate(incoming(HOLDING)))
        assertEquals(CallEvent.Changed(incoming(ACTIVE)), tracker.onUpdate(incoming(ACTIVE)))
        assertEquals(CallEvent.Ended(incoming(DISCONNECTED), reason = null), tracker.onUpdate(incoming(DISCONNECTED)))
    }

    @Test
    fun `call first seen as active counts as answered`() {
        assertEquals(CallEvent.Answered(incoming(ACTIVE)), tracker.onUpdate(incoming(ACTIVE)))
        assertEquals(CallEvent.Ended(incoming(DISCONNECTED), reason = null), tracker.onUpdate(incoming(DISCONNECTED)))
    }

    @Test
    fun `disconnect for an unknown call is ignored`() {
        assertNull(tracker.onUpdate(incoming(DISCONNECTED, id = "ghost")))
    }

    @Test
    fun `call waiting is tracked independently`() {
        tracker.onUpdate(incoming(RINGING, id = "first"))
        tracker.onUpdate(incoming(ACTIVE, id = "first"))
        assertEquals(CallEvent.Ringing(incoming(RINGING, id = "second")), tracker.onUpdate(incoming(RINGING, id = "second")))
        assertEquals(
            CallEvent.Ended(incoming(DISCONNECTED, id = "second"), reason = EndReason.MISSED),
            tracker.onUpdate(incoming(DISCONNECTED, id = "second")),
        )
        assertEquals(listOf(incoming(ACTIVE, id = "first")), tracker.liveCalls)
    }

    @Test
    fun `liveCalls follows the call lifecycle and keeps the latest snapshot`() {
        assertTrue(tracker.liveCalls.isEmpty())
        tracker.onUpdate(incoming(RINGING))
        tracker.onUpdate(incoming(ACTIVE))
        assertEquals(listOf(incoming(ACTIVE)), tracker.liveCalls)
        tracker.onUpdate(incoming(DISCONNECTED))
        assertTrue(tracker.liveCalls.isEmpty())
    }
}
