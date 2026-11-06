package com.cellbridge.di

import com.cellbridge.spam.FileSpamStore
import com.cellbridge.spam.PlatformScreeningRole
import com.cellbridge.spam.ScreeningRole
import com.cellbridge.spam.SpamDesk
import com.cellbridge.spam.SpamGuard
import com.cellbridge.spam.SpamStore
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
abstract class SpamModule {
    @Binds abstract fun store(impl: FileSpamStore): SpamStore

    @Binds abstract fun desk(impl: SpamGuard): SpamDesk

    @Binds abstract fun role(impl: PlatformScreeningRole): ScreeningRole
}
