package com.cellbridge.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class VoiceVolumeLockTest {
    private class FakeVolume(var current: Int = 9, var failSet: Boolean = false) : VoiceVolumePort {
        override fun level() = current
        override fun lowest() = 1
        override fun set(level: Int) { if (failSet) error("denied"); current = level }
    }

    private class FakeSaved(var value: Int? = null, var failSave: Boolean = false) : SavedLevel {
        override fun load() = value
        override fun save(level: Int) { if (failSave) error("disk full"); value = level }
        override fun clear() { value = null }
    }

    @Test fun `the volume goes down while audio runs and comes back`() {
        val volume = FakeVolume(); val saved = FakeSaved()
        val lock = VoiceVolumeLock(volume, saved)
        lock.acquire()
        assertEquals(1, volume.current)
        assertEquals(9, saved.value)
        lock.release()
        assertEquals(9, volume.current)
        assertEquals(null, saved.value)
    }

    @Test fun `a second acquire does not save the lowered level over the original`() {
        val volume = FakeVolume(); val saved = FakeSaved()
        val lock = VoiceVolumeLock(volume, saved)
        lock.acquire(); lock.acquire()
        lock.release()
        assertEquals(9, volume.current)
    }

    @Test fun `release without acquire changes nothing`() {
        val volume = FakeVolume(current = 6)
        VoiceVolumeLock(volume, FakeSaved()).release()
        assertEquals(6, volume.current)
    }

    @Test fun `a volume left down by a killed process is put back by the next release`() {
        val volume = FakeVolume(current = 1); val saved = FakeSaved(value = 12)
        VoiceVolumeLock(volume, saved).release()
        assertEquals(12, volume.current)
        assertEquals(null, saved.value)
    }

    @Test fun `when the level cannot be saved the volume is left alone`() {
        val volume = FakeVolume(); val saved = FakeSaved(failSave = true)
        VoiceVolumeLock(volume, saved).acquire()
        assertEquals(9, volume.current)
    }

    @Test fun `when putting the volume back fails the saved level is kept for a retry`() {
        val volume = FakeVolume(current = 1, failSet = true); val saved = FakeSaved(value = 9)
        val lock = VoiceVolumeLock(volume, saved)
        lock.release()
        assertEquals(9, saved.value)
        volume.failSet = false
        lock.release()
        assertEquals(9, volume.current)
        assertEquals(null, saved.value)
    }

    @Test fun `one failing lock does not keep the others held`() {
        var released = false
        val bad = object : LinkLock { override fun acquire() = error("x"); override fun release() = error("x") }
        val good = object : LinkLock { override fun acquire() = Unit; override fun release() { released = true } }
        AllLocks(bad, good).release()
        assertEquals(true, released)
    }
}
