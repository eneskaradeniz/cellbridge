package com.cellbridge.sms

import android.app.Service
import android.content.Intent
import android.os.IBinder

/** Required for the default SMS role ("reply with message" while rejecting a call); not implemented. */
class RespondViaMessageService : Service() {
    override fun onBind(intent: Intent): IBinder? = null
}
