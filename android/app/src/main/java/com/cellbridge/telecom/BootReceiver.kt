package com.cellbridge.telecom

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.cellbridge.server.ControlService

/** Brings the control server up after a reboot or an app update, without anyone opening the app. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            ControlService.start(context)
        }
    }
}
