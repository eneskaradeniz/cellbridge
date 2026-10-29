package com.cellbridge.di

import com.cellbridge.audio.AudioDaemonClient
import android.content.Context
import com.cellbridge.audio.CallAudio
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
    fun callAudio(token: PairingToken, @ApplicationContext context: Context): CallAudio =
        LockedCallAudio(AudioDaemonClient(token.value), WifiLinkLock(context))
}
