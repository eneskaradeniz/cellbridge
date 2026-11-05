package com.cellbridge.di

import com.cellbridge.audio.AudioDaemonClient
import android.content.Context
import com.cellbridge.audio.AllLocks
import com.cellbridge.audio.AudioManagerVoiceVolume
import com.cellbridge.audio.CallAudio
import com.cellbridge.audio.PrefsSavedLevel
import com.cellbridge.audio.ToneEvents
import com.cellbridge.audio.ToneParser
import com.cellbridge.audio.VoiceVolumeLock
import com.cellbridge.audio.LockedCallAudio
import com.cellbridge.audio.WifiLinkLock
import com.cellbridge.server.PairingToken
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AudioModule {
    /** The daemon is started with the pairing token as its secret (docs/protocol.md). */
    @Provides @Singleton
    fun callAudio(token: PairingToken, @ApplicationContext context: Context, tones: ToneEvents): CallAudio {
        // Created once per process, when nothing can be relayed yet: releasing first puts back a call volume
        // left turned down by a process that was killed mid-call.
        val locks = AllLocks(WifiLinkLock(context), VoiceVolumeLock(AudioManagerVoiceVolume(context), PrefsSavedLevel(context)).also { it.release() })
        // When the daemon is lost for good the relay is over: let go of what was held for it.
        // Telecom's own sound files are named by resource id in its log; the name is what the iPhone needs.
        val parser = ToneParser(mediaName = { id ->
            runCatching { context.packageManager.getResourcesForApplication(TELECOM).getResourceEntryName(id) }.getOrNull()
        })
        return LockedCallAudio(
            AudioDaemonClient(token.value, onLost = locks::release, onToneLine = { line -> parser.parse(line)?.let(tones::emit) }),
            locks,
        )
    }

    private const val TELECOM = "com.android.server.telecom"
}
