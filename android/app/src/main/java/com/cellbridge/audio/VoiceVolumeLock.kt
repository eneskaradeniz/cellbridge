package com.cellbridge.audio

import android.content.Context
import android.media.AudioManager

/** The phone's call volume, as far as the lock below needs it. */
interface VoiceVolumePort {
    fun level(): Int
    fun lowest(): Int
    fun set(level: Int)
}

/** Where the user's volume waits while it is turned down; must survive the process being killed. */
interface SavedLevel {
    fun load(): Int?
    fun save(level: Int)
    fun clear()
}

/**
 * While a call's audio runs on the iPhone, the phone's own earpiece is turned down to its lowest level: the iPhone
 * plays the call, and two loud copies make an echo. (The relay taps the call before the volume stage, so the iPhone
 * is not affected.) The call volume is a lasting user setting, so the original level is saved first and put back
 * on every way out: the relay stopping, a refused start, and the next start of the app after a crash.
 */
class VoiceVolumeLock(private val volume: VoiceVolumePort, private val saved: SavedLevel) : LinkLock {
    override fun acquire() {
        runCatching {
            if (saved.load() == null) saved.save(volume.level()) // saved before anything is touched
            volume.set(volume.lowest())
        }
    }

    /** Idempotent: does nothing when the volume is not turned down. */
    override fun release() {
        runCatching {
            val level = saved.load() ?: return
            volume.set(level)
            saved.clear() // kept if setting failed, so that the next release retries
        }
    }
}

class AudioManagerVoiceVolume(context: Context) : VoiceVolumePort {
    private val audio = context.applicationContext.getSystemService(AudioManager::class.java)
    override fun level() = audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
    override fun lowest() = audio.getStreamMinVolume(AudioManager.STREAM_VOICE_CALL)
    override fun set(level: Int) = audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, level, 0)
}

class PrefsSavedLevel(context: Context) : SavedLevel {
    private val prefs = context.applicationContext.getSharedPreferences("voice_volume", Context.MODE_PRIVATE)
    override fun load(): Int? = if (prefs.contains(KEY)) prefs.getInt(KEY, 0) else null
    override fun save(level: Int) { check(prefs.edit().putInt(KEY, level).commit()) { "could not save the call volume" } }
    override fun clear() { prefs.edit().remove(KEY).commit() }

    private companion object { const val KEY = "level" }
}

/** Several locks that are taken and let go together; one failing never keeps the others held. */
class AllLocks(private vararg val locks: LinkLock) : LinkLock {
    override fun acquire() = locks.forEach { runCatching(it::acquire) }
    override fun release() = locks.forEach { runCatching(it::release) }
}
