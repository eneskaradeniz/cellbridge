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
    }

    private val registry = CallRegistry()

    @Test
    fun `commands reach the registered call`() {
        val handle = RecordingHandle().also { registry.register("c1", it) }
        assertTrue(registry.answer("c1"))
        assertTrue(registry.reject("c1"))
        assertTrue(registry.hangup("c1"))
        assertEquals(listOf("answer", "reject", "hangup"), handle.actions)
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
