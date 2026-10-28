package com.cellbridge.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.telecom.TelecomManager

/**
 * `adb shell am broadcast -n com.cellbridge/.debug.FakeCallReceiver -a com.cellbridge.debug.INCOMING_CALL`
 * rings a fake call; `-a com.cellbridge.debug.REMOTE_HANGUP` makes the fake caller hang up;
 * `-a com.cellbridge.debug.REGISTER_ACCOUNT` only registers the fake phone account (to enable it or make it the
 * outgoing account with the `telecom` shell command).
 */
class FakeCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            INCOMING_CALL -> {
                val handle = FakeCallService.register(context)
                val extras = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts("tel", FAKE_NUMBER, null))
                }
                context.getSystemService(TelecomManager::class.java).addNewIncomingCall(handle, extras)
            }
            REMOTE_HANGUP -> FakeCallService.current?.hangUpRemotely()
            REGISTER_ACCOUNT -> FakeCallService.register(context)
        }
    }

    private companion object {
        const val INCOMING_CALL = "com.cellbridge.debug.INCOMING_CALL"
        const val REMOTE_HANGUP = "com.cellbridge.debug.REMOTE_HANGUP"
        const val REGISTER_ACCOUNT = "com.cellbridge.debug.REGISTER_ACCOUNT"
        const val FAKE_NUMBER = "+905550000000"
    }
}
