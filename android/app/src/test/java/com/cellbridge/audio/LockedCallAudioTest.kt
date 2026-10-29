package com.cellbridge.audio

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.InetSocketAddress

class LockedCallAudioTest {
    private class FakeLink : LinkLock {
        var held = false
        override fun acquire() { held = true }
        override fun release() { held = false }
    }

    private class FakeAudio(var startResult: Boolean = true) : CallAudio {
        override suspend fun isAvailable() = true
        override suspend fun start(peer: InetSocketAddress) = startResult
        override suspend fun stop() = Unit
    }

    private val peer = InetSocketAddress("192.168.1.10", 5000)

    @Test fun `the lock is held from a successful start until stop`() = runTest {
        val link = FakeLink()
        val audio = LockedCallAudio(FakeAudio(), link)
        audio.start(peer)
        assertEquals(true, link.held)
        audio.stop()
        assertEquals(false, link.held)
    }

    @Test fun `a refused start holds nothing`() = runTest {
        val link = FakeLink()
        assertEquals(false, LockedCallAudio(FakeAudio(startResult = false), link).start(peer))
        assertEquals(false, link.held)
    }
}
