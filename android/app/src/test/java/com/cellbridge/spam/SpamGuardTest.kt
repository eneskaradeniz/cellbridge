package com.cellbridge.spam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpamGuardTest {
    private class MemoryStore : SpamStore {
        var saved = SpamState()
        override fun load() = saved
        override fun save(state: SpamState) { saved = state }
    }

    private val guard = SpamGuard(MemoryStore(), { true })

    @Test fun `a blocked text is logged and announced`() {
        assertTrue(guard.screenSms("5551112233", "Canlı bahis fırsatı", 5))
        val snap = kotlinx.coroutines.runBlocking { guard.snapshot() }
        assertEquals(listOf("sms"), snap.items.map { it.kind })
        assertEquals("gambling", snap.items.single().reason)
        assertTrue(snap.screening)
    }

    @Test fun `report then not spam round trips`() = kotlinx.coroutines.runBlocking {
        guard.report("+905321234567", "merhaba bu bir deneme metnidir ve yeterince uzundur")
        assertTrue(guard.isSpamSms("05321234567", "başka"))
        assertTrue(guard.snapshot().items.isNotEmpty())
        guard.notSpam("05321234567")
        assertFalse(guard.isSpamSms("05321234567", "başka"))
        assertTrue(guard.snapshot().items.isEmpty())
    }

    @Test fun `contacts sync replaces the list and keeps only keys`() = kotlinx.coroutines.runBlocking {
        guard.setStrict(true)
        guard.syncContacts(listOf("5321234567"))
        assertFalse(guard.screenCall("+905321234567"))
        assertTrue(guard.screenCall("+905329999999"))
        guard.syncContacts(emptyList())
        assertTrue(guard.screenCall("+905321234567"))
    }
}
