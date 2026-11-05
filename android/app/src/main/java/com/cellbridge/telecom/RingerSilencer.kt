package com.cellbridge.telecom

import android.app.NotificationManager
import android.content.Context

/** The phone's Do Not Disturb setting, as far as silencing a ringing call needs it. */
interface DoNotDisturb {
    /** The user (or adb) gave the app Do Not Disturb access. */
    val allowed: Boolean
    var filter: Int
}

/** Where the filter to go back to is kept, so a crash in the middle of a call cannot leave the phone silent for good. */
interface SavedFilter {
    var value: Int?
}

/**
 * Stops the phone's ringtone and vibration for a call that is ringing on the iPhone as well, without being the default dialer
 * (only that can call TelecomManager.silenceRinger): Do Not Disturb "alarms only" for as long as a call rings, then back to what it was.
 */
class RingerSilencer(private val dnd: DoNotDisturb, private val saved: SavedFilter) {
    /** False when it cannot (no access): the phone just keeps ringing. */
    fun silence(): Boolean {
        if (!dnd.allowed) return false
        if (saved.value == null) {
            val current = dnd.filter
            if (current == QUIET || current == NONE) return true // already silent: nothing to put back
            saved.value = current
        }
        dnd.filter = QUIET
        return true
    }

    /** Puts the filter back; does nothing when [silence] did not change it. */
    fun restore() {
        val previous = saved.value ?: return
        saved.value = null
        if (dnd.allowed) dnd.filter = previous
    }

    companion object {
        private const val NONE = NotificationManager.INTERRUPTION_FILTER_NONE
        const val QUIET = NotificationManager.INTERRUPTION_FILTER_ALARMS

        fun forContext(context: Context): RingerSilencer {
            val manager = context.getSystemService(NotificationManager::class.java)
            val prefs = context.getSharedPreferences("ringer", Context.MODE_PRIVATE)
            return RingerSilencer(
                object : DoNotDisturb {
                    override val allowed get() = manager.isNotificationPolicyAccessGranted
                    override var filter: Int
                        get() = manager.currentInterruptionFilter
                        set(value) = manager.setInterruptionFilter(value)
                },
                object : SavedFilter {
                    override var value: Int?
                        get() = if (prefs.contains("saved")) prefs.getInt("saved", 0) else null
                        set(v) = prefs.edit().apply { if (v == null) remove("saved") else putInt("saved", v) }.apply()
                },
            )
        }
    }
}
