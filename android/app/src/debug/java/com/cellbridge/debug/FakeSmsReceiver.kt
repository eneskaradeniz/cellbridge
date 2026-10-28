package com.cellbridge.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.cellbridge.sms.SmsRepository
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/**
 * `adb shell am broadcast -n com.cellbridge/.debug.FakeSmsReceiver -a com.cellbridge.debug.INCOMING_SMS
 *  --es from +905550000000 --es body "hello"` feeds a received text into the same path as a real SMS_DELIVER
 * (everything after the PDU parsing). Needs the default SMS role, like the real thing.
 */
@AndroidEntryPoint
class FakeSmsReceiver : BroadcastReceiver() {
    @Inject lateinit var repository: SmsRepository

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "com.cellbridge.debug.INCOMING_SMS") return
        val pending = goAsync()
        repository.onReceived(
            from = intent.getStringExtra("from") ?: "+905550000000",
            body = intent.getStringExtra("body") ?: "debug sms",
            timestamp = System.currentTimeMillis(),
        ).invokeOnCompletion { pending.finish() }
    }
}
