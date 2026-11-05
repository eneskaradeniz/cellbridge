package com.cellbridge.di

import com.cellbridge.history.HistorySource
import com.cellbridge.history.TelephonyHistory
import com.cellbridge.sms.LedgerStore
import com.cellbridge.sms.PlatformSmsSender
import com.cellbridge.sms.PrefsLedgerStore
import com.cellbridge.sms.SmsGateway
import com.cellbridge.sms.SmsRepository
import com.cellbridge.sms.SMS_PERMISSIONS
import com.cellbridge.sms.SmsRole
import com.cellbridge.sms.SmsSender
import com.cellbridge.sms.SmsStore
import com.cellbridge.sms.TelephonySmsStore
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import dagger.hilt.android.qualifiers.ApplicationContext
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

    @Binds abstract fun ledgerStore(impl: PrefsLedgerStore): LedgerStore

    companion object {
        /** The permissions are what the host needs now that the phone's stock Messages app is the default SMS app. */
        @Provides fun role(@ApplicationContext context: Context): SmsRole = SmsRole {
            SMS_PERMISSIONS.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        }
    }
}
