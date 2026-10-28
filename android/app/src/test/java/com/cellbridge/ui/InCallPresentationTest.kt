package com.cellbridge.ui

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class InCallPresentationTest {
    private fun call(id: String, status: CallStatus, direction: CallDirection = CallDirection.INCOMING) =
        CallSnapshot(id, "+905551112233", direction, status)

    @Test
    fun `a ringing call comes first, then the one in progress, then anything else`() {
        val active = call("a", CallStatus.ACTIVE)
        val ringing = call("r", CallStatus.RINGING)
        val dialing = call("d", CallStatus.DIALING, CallDirection.OUTGOING)

        assertEquals(ringing, primaryCall(listOf(active, ringing)))
        assertEquals(active, primaryCall(listOf(dialing, active)))
        assertEquals(dialing, primaryCall(listOf(dialing)))
        assertNull(primaryCall(emptyList()))
    }

    @Test
    fun `an outgoing call that rings remotely is not an incoming one`() {
        val outgoing = call("o", CallStatus.RINGING, CallDirection.OUTGOING)
        val active = call("a", CallStatus.ACTIVE)
        assertEquals(active, primaryCall(listOf(outgoing, active)))
    }

    @Test
    fun `phases follow the call status`() {
        assertEquals(CallPhase.INCOMING, phaseOf(call("1", CallStatus.RINGING)))
        assertEquals(CallPhase.DIALING, phaseOf(call("2", CallStatus.DIALING)))
        assertEquals(CallPhase.ACTIVE, phaseOf(call("3", CallStatus.ACTIVE)))
        assertEquals(CallPhase.HOLDING, phaseOf(call("4", CallStatus.HOLDING)))
    }

    @Test
    fun `elapsed time is formatted like a phone`() {
        assertEquals("0:00", formatElapsed(0))
        assertEquals("0:09", formatElapsed(9_999))
        assertEquals("1:05", formatElapsed(65_000))
        assertEquals("59:59", formatElapsed(3_599_000))
        assertEquals("1:00:00", formatElapsed(3_600_000))
        assertEquals("0:00", formatElapsed(-5_000))
    }
}
