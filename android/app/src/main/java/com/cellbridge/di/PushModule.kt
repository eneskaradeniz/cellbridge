package com.cellbridge.di

import com.cellbridge.push.ApnsCredentialSource
import com.cellbridge.push.ApnsTransport
import com.cellbridge.push.FileApnsCredentials
import com.cellbridge.push.FilePushStore
import com.cellbridge.push.OkHttpApnsTransport
import com.cellbridge.push.PushStore
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
abstract class PushModule {
    @Binds abstract fun store(impl: FilePushStore): PushStore

    @Binds abstract fun credentials(impl: FileApnsCredentials): ApnsCredentialSource

    @Binds abstract fun transport(impl: OkHttpApnsTransport): ApnsTransport
}
