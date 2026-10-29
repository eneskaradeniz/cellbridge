package com.cellbridge.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SmsMessage
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/** The operator's delivery report for a text sent through the bridge (an SMS status report PDU). */
@AndroidEntryPoint
class SmsDeliveryReceiver : BroadcastReceiver() {
    @Inject lateinit var repository: SmsRepository

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        val tag = intent.getStringExtra(TAG) ?: return
        val pdu = intent.getByteArrayExtra("pdu") ?: return
        val status = runCatching { SmsMessage.createFromPdu(pdu, intent.getStringExtra("format")).status }.getOrNull() ?: return
        deliveryOutcome(status)?.let { repository.onDelivery(tag, it) }
    }

    companion object {
        const val ACTION = "com.cellbridge.SMS_DELIVERED"
        const val TAG = "tag"
    }
}
