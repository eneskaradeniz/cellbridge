package com.cellbridge.di

import com.cellbridge.telecom.CallCommands
import com.cellbridge.telecom.CallFeed
import com.cellbridge.telecom.CallDialer
import com.cellbridge.telecom.CallRegistry
import com.cellbridge.telecom.OutgoingCalls
import com.cellbridge.telecom.PlatformTelecom
import com.cellbridge.telecom.TelecomPlacer
import com.cellbridge.telecom.CallRepository
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
abstract class AppModule {
    @Binds abstract fun callFeed(impl: CallRepository): CallFeed

    @Binds abstract fun callCommands(impl: CallRegistry): CallCommands

    @Binds abstract fun callDialer(impl: OutgoingCalls): CallDialer

    @Binds abstract fun telecomPlacer(impl: PlatformTelecom): TelecomPlacer
}
