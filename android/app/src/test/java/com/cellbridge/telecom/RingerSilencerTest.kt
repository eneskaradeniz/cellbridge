package com.cellbridge.telecom

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RingerSilencerTest {
    private val all = 1 // INTERRUPTION_FILTER_ALL
    private val priority = 2
    private val none = 3

    private class FakeDnd(override var allowed: Boolean, override var filter: Int) : DoNotDisturb
    private class FakeSaved : SavedFilter { override var value: Int? = null }

    @Test fun `silences while a call rings and puts the setting back`() {
        val dnd = FakeDnd(true, priority)
        val silencer = RingerSilencer(dnd, FakeSaved())
        assertTrue(silencer.silence())
        assertEquals(RingerSilencer.QUIET, dnd.filter)
        silencer.restore()
        assertEquals(priority, dnd.filter)
    }

    @Test fun `a second silence does not overwrite what to go back to`() {
        val dnd = FakeDnd(true, all)
        val silencer = RingerSilencer(dnd, FakeSaved())
        silencer.silence()
        silencer.silence()
        silencer.restore()
        assertEquals(all, dnd.filter)
    }

    @Test fun `without access nothing changes`() {
        val dnd = FakeDnd(false, all)
        val silencer = RingerSilencer(dnd, FakeSaved())
        assertFalse(silencer.silence())
        silencer.restore()
        assertEquals(all, dnd.filter)
    }

    @Test fun `already silent stays as the user had it`() {
        val dnd = FakeDnd(true, none)
        val saved = FakeSaved()
        val silencer = RingerSilencer(dnd, saved)
        assertTrue(silencer.silence())
        assertNull(saved.value)
        silencer.restore()
        assertEquals(none, dnd.filter)
    }

    @Test fun `a new instance restores what a crashed one left`() {
        val dnd = FakeDnd(true, all)
        val saved = FakeSaved()
        RingerSilencer(dnd, saved).silence()
        RingerSilencer(dnd, saved).restore() // after the process was killed mid-call
        assertEquals(all, dnd.filter)
    }

    @Test fun `restore without a silence is harmless`() {
        val dnd = FakeDnd(true, priority)
        RingerSilencer(dnd, FakeSaved()).restore()
        assertEquals(priority, dnd.filter)
    }
}
