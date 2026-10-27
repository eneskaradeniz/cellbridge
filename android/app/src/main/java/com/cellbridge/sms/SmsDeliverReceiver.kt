package com.cellbridge.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Required for the default SMS role. Delivery handling arrives in M4. */
class SmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Unit
}
