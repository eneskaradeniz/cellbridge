package com.cellbridge.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Required for the default SMS role; MMS is out of scope, so incoming MMS is ignored. */
class MmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Unit
}
