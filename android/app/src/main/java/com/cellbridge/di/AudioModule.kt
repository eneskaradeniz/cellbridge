package com.cellbridge.di

import com.cellbridge.audio.AudioDaemonClient
import com.cellbridge.audio.CallAudio
import com.cellbridge.server.PairingToken
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AudioModule {
    /** The daemon is started with the pairing token as its secret (docs/protocol.md). */
    @Provides @Singleton
    fun callAudio(token: PairingToken): CallAudio = AudioDaemonClient(token.value)
}
