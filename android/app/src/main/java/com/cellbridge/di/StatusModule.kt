package com.cellbridge.di

import com.cellbridge.status.HostStatusReader
import com.cellbridge.status.PhoneStatusSource
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
abstract class StatusModule {
    @Binds abstract fun source(impl: HostStatusReader): PhoneStatusSource
}
