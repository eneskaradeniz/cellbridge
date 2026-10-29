package com.cellbridge.history

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CallKindTest {
    @Test fun `platform call types map to the wire kinds`() {
        assertEquals("incoming", callKind(1))
        assertEquals("outgoing", callKind(2))
        assertEquals("missed", callKind(3))
        assertEquals("rejected", callKind(5))
        assertEquals("rejected", callKind(6)) // blocked
        assertEquals("incoming", callKind(7)) // answered on another device
    }

    @Test fun `voicemail and unknown types are skipped`() {
        assertNull(callKind(4))
        assertNull(callKind(99))
    }
}
