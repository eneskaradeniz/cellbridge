package com.cellbridge.telecom

import android.content.Context
import android.os.PowerManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Keeps the CPU awake while a call is live. Without it the CPU suspends and the DSP audio feed stalls
 * 300-450 ms at a time (docs/spike-a-android-audio.md). Held by the app, not the daemon: the platform
 * releases it if this process dies; the timeout is only a backstop against a missed release.
 */
@Singleton
class CallWakeLock @Inject constructor(@ApplicationContext context: Context) {
    private val lock = context.getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CellBridge:call")
        .apply { setReferenceCounted(false) }

    fun setHeld(held: Boolean) {
        when {
            held && !lock.isHeld -> lock.acquire(MAX_CALL_MILLIS)
            !held && lock.isHeld -> lock.release()
        }
    }

    private companion object {
        const val MAX_CALL_MILLIS = 4 * 60 * 60 * 1000L
    }
}
