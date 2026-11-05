package com.cellbridge.hotspot

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeWifi(var script: MutableList<WifiNetworks?>, var startWorks: Boolean = true) : WifiDaemon {
    val calls = mutableListOf<Boolean>()
    override suspend fun networks(): WifiNetworks? = if (script.size > 1) script.removeAt(0) else script.firstOrNull()
    override suspend fun hotspot(on: Boolean): Boolean { calls += on; return startWorks }
}

private class MemoryStore(override var enabled: Boolean = true, override var started: Boolean = false) : HotspotStore

class AutoHotspotLogicTest {
    private val home = WifiNetworks("HomeNet_5GHz", setOf("HomeNet_5GHz", "HomeNet_2.4GHz"))
    private val away = WifiNetworks(null, home.saved)
    private fun logic(w: WifiDaemon, s: HotspotStore) = AutoHotspotLogic(w, s, graceMs = 0, retryMs = 0)

    @Test fun `at home nothing is started`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(home)); val store = MemoryStore()
        logic(wifi, store).reconcile()
        assertEquals(emptyList<Boolean>(), wifi.calls)
    }

    @Test fun `still away after the grace switches the hotspot on and remembers it`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(away, away)); val store = MemoryStore()
        logic(wifi, store).reconcile()
        assertEquals(listOf(true), wifi.calls)
        assertTrue(store.started)
    }

    @Test fun `a blip that is over after the grace does nothing`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(away, home)); val store = MemoryStore()
        logic(wifi, store).reconcile()
        assertEquals(emptyList<Boolean>(), wifi.calls)
        assertFalse(store.started)
    }

    @Test fun `back home stops a hotspot this app started`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(home)); val store = MemoryStore(started = true)
        logic(wifi, store).reconcile()
        assertEquals(listOf(false), wifi.calls)
        assertFalse(store.started)
    }

    @Test fun `a hotspot switched on by hand is left alone at home`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(home)); val store = MemoryStore(started = false)
        logic(wifi, store).reconcile()
        assertEquals(emptyList<Boolean>(), wifi.calls)
    }

    @Test fun `connected to a network that is not saved counts as away`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(WifiNetworks("Cafe", home.saved))); val store = MemoryStore()
        logic(wifi, store).reconcile()
        assertEquals(listOf(true), wifi.calls)
    }

    @Test fun `switched off, a running hotspot is stopped and none is started`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(away)); val store = MemoryStore(enabled = false, started = true)
        logic(wifi, store).reconcile()
        assertEquals(listOf(false), wifi.calls)
        assertFalse(store.started)
    }

    @Test fun `an unreachable daemon is retried and then given up`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(null)); val store = MemoryStore()
        logic(wifi, store).reconcile()
        assertEquals(emptyList<Boolean>(), wifi.calls)
    }

    @Test fun `a failed start is not recorded as started`() = runBlocking {
        val wifi = FakeWifi(mutableListOf(away), startWorks = false); val store = MemoryStore()
        logic(wifi, store).reconcile()
        assertFalse(store.started)
        assertEquals(listOf(true, true, true), wifi.calls) // retried, then given up
    }

    @Test fun `the daemon's reply is read as a connected name and saved names`() {
        assertEquals(WifiNetworks("A", setOf("A", "B")), parseNetworks("A\nA\nB\n"))
        assertEquals(WifiNetworks(null, setOf("B")), parseNetworks("\nB\n"))
    }
}
