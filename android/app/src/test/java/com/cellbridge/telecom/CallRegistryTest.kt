package com.cellbridge.telecom

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallRegistryTest {
    private class RecordingHandle : CallHandle {
        val actions = mutableListOf<String>()
        override fun answer() { actions += "answer" }
        override fun reject() { actions += "reject" }
        override fun hangup() { actions += "hangup" }
        override fun silence() { actions += "silence" }
        override fun dtmf(digit: Char) { actions += "dtmf:$digit" }
        override fun hold() { actions += "hold" }
        override fun unhold() { actions += "unhold" }
    }

    private val registry = CallRegistry()

    @Test
    fun `commands reach the registered call`() {
        val handle = RecordingHandle().also { registry.register("c1", it) }
        assertTrue(registry.answer("c1"))
        assertTrue(registry.reject("c1"))
        assertTrue(registry.hangup("c1"))
        assertTrue(registry.silence("c1"))
        assertTrue(registry.dtmf("c1", '7'))
        assertTrue(registry.hold("c1"))
        assertTrue(registry.unhold("c1"))
        assertEquals(listOf("answer", "reject", "hangup", "silence", "dtmf:7", "hold", "unhold"), handle.actions)
    }

    @Test
    fun `unknown and unregistered calls are refused`() {
        assertFalse(registry.answer("nope"))
        val handle = RecordingHandle().also { registry.register("c1", it) }
        registry.unregister("c1")
        assertFalse(registry.hangup("c1"))
        assertEquals(emptyList<String>(), handle.actions)
    }
}
