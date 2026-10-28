package com.cellbridge.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/** Required for the default SMS role; hands each received text to [SmsRepository]. */
@AndroidEntryPoint
class SmsDeliverReceiver : BroadcastReceiver() {
    @Inject lateinit var repository: SmsRepository

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return
        // A multipart text arrives as one broadcast with one message per part.
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent).orEmpty()
        val first = parts.firstOrNull() ?: return
        val body = parts.joinToString("") { it.messageBody.orEmpty() }
        val pending = goAsync()
        repository.onReceived(first.originatingAddress.orEmpty(), body, first.timestampMillis)
            .invokeOnCompletion { pending.finish() }
    }
}
