package com.cellbridge.sms

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/** Watches the SMS inbox, where the stock Messages app stores what arrives, and hands each new text to [SmsRepository]. */
@Singleton
class InboxWatcher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val repository: SmsRepository,
) {
    private var started = false

    /** Once per process. */
    @Synchronized
    fun start() {
        if (started) return
        started = true
        CoroutineScope(SupervisorJob() + Dispatchers.Default).launch { repository.primeInbox() }
        // The provider announces inserts on content://sms itself, not on /inbox, so that parent is the one to watch.
        runCatching {
            context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    repository.onInboxChanged()
                }
            })
        }.onFailure { Log.w("CellBridge", "inbox not watched: ${it::class.simpleName}") }
    }
}
