package com.cellbridge.di

import com.cellbridge.audio.AudioDaemonClient
import android.content.Context
import com.cellbridge.audio.AllLocks
import com.cellbridge.audio.AudioManagerVoiceVolume
import com.cellbridge.audio.CallAudio
import com.cellbridge.audio.PrefsSavedLevel
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
    fun callAudio(token: PairingToken, @ApplicationContext context: Context): CallAudio {
        // Created once per process, when nothing can be relayed yet: releasing first puts back a call volume
        // left turned down by a process that was killed mid-call.
        val locks = AllLocks(WifiLinkLock(context), VoiceVolumeLock(AudioManagerVoiceVolume(context), PrefsSavedLevel(context)).also { it.release() })
        // When the daemon is lost for good the relay is over: let go of what was held for it.
        return LockedCallAudio(AudioDaemonClient(token.value, onLost = locks::release), locks)
    }
}
