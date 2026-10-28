package com.cellbridge.sms

import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsRepositoryTest {
    private class FakeStore : SmsStore {
        var nextId = 7L
        var refuse = false
        var failSent = false
        val savedIncoming = mutableListOf<IncomingSms>()
        val savedSent = mutableListOf<Pair<String, String>>()
        val acknowledged = mutableListOf<Long>()
        var pending = emptyList<IncomingSms>()

        override suspend fun saveIncoming(from: String, body: String, timestamp: Long): IncomingSms? {
            if (refuse) return null
            return IncomingSms(nextId++, from, body, timestamp).also { savedIncoming += it }
        }
        override suspend fun saveSent(to: String, body: String, timestamp: Long) {
            check(!failSent) { "db full" }
            savedSent += to to body
        }
        override suspend fun unacknowledged() = pending
        override fun acknowledge(id: Long) { acknowledged += id }
    }

    private class FakeSender(var ok: Boolean = true) : SmsSender {
        val calls = mutableListOf<Pair<String, String>>()
        override suspend fun send(to: String, body: String): Boolean = ok.also { calls += to to body }
    }

    private val store = FakeStore()
    private val sender = FakeSender()
    private var role = true
    private val repository = SmsRepository(store, sender) { role }

    @Test
    fun `a received text is stored first and then announced with its stored id`() = runBlocking {
        val announced = async(start = CoroutineStart.UNDISPATCHED) { repository.incoming.first() }
        repository.onReceived("+90555", "merhaba", 123L).join()
        assertEquals(IncomingSms(7, "+90555", "merhaba", 123L), withTimeout(5_000) { announced.await() })
        assertEquals(listOf(IncomingSms(7, "+90555", "merhaba", 123L)), store.savedIncoming)
    }

    @Test
    fun `a text the database refuses is not announced`() = runBlocking {
        store.refuse = true
        val announced = async(start = CoroutineStart.UNDISPATCHED) { repository.incoming.first() }
        repository.onReceived("+90555", "merhaba", 1L).join()
        assertTrue(!announced.isCompleted)
        announced.cancel()
    }

    @Test
    fun `acknowledge and the unacknowledged list go straight to the store`() = runBlocking {
        store.pending = listOf(IncomingSms(3, "+90555", "x", 1L))
        assertEquals(store.pending, repository.unacknowledged())
        repository.acknowledge(3)
        assertEquals(listOf(3L), store.acknowledged)
    }

    @Test
    fun `sending validates the number and the body before touching the radio`() = runBlocking {
        assertEquals(SendResult.Failed("invalid"), repository.send("not a number", "hi"))
        assertEquals(SendResult.Failed("invalid"), repository.send("+90555", "   "))
        assertEquals(SendResult.Failed("invalid"), repository.send("+90555", "x".repeat(1_001)))
        assertEquals(emptyList<Pair<String, String>>(), sender.calls)
    }

    @Test
    fun `a sent text is recorded, a refused one is not`() = runBlocking {
        assertEquals(SendResult.Sent, repository.send("+90 555 111 22 33", "selam"))
        assertEquals(listOf("+90 555 111 22 33" to "selam"), store.savedSent)

        sender.ok = false
        assertEquals(SendResult.Failed("failed"), repository.send("+90555", "yine"))
        assertEquals(1, store.savedSent.size)
    }

    @Test
    fun `a failure to record a sent text does not turn the send into a failure`() = runBlocking {
        store.failSent = true
        assertEquals(SendResult.Sent, repository.send("+90555", "selam"))
    }

    @Test
    fun `availability follows the default sms app role`() {
        assertTrue(repository.isAvailable())
        role = false
        assertTrue(!repository.isAvailable())
    }
}
