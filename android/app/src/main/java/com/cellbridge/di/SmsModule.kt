package com.cellbridge.di

import com.cellbridge.history.HistorySource
import com.cellbridge.history.TelephonyHistory
import com.cellbridge.sms.PlatformSmsSender
import com.cellbridge.sms.SmsGateway
import com.cellbridge.sms.SmsRepository
import com.cellbridge.sms.SmsRole
import com.cellbridge.sms.SmsSender
import com.cellbridge.sms.SmsStore
import com.cellbridge.sms.TelephonySmsStore
import com.cellbridge.telecom.AppRole
import com.cellbridge.telecom.DefaultRoles
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@Module
@InstallIn(SingletonComponent::class)
abstract class SmsModule {
    @Binds abstract fun store(impl: TelephonySmsStore): SmsStore

    @Binds abstract fun sender(impl: PlatformSmsSender): SmsSender

    @Binds abstract fun gateway(impl: SmsRepository): SmsGateway

    @Binds abstract fun history(impl: TelephonyHistory): HistorySource

    companion object {
        @Provides fun role(roles: DefaultRoles): SmsRole = SmsRole { roles.isHeld(AppRole.SMS) }
    }
}
