package com.cellbridge.telecom

import android.telecom.Call
import android.telecom.CallScreeningService
import com.cellbridge.spam.SpamGuard
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

/** Rejects incoming calls the spam filter blocks, before they ring on the phone or the iPhone; the stock call log still lists them. */
@AndroidEntryPoint
class CellBridgeCallScreeningService : CallScreeningService() {
    @Inject lateinit var spam: SpamGuard

    override fun onScreenCall(details: Call.Details) {
        val block = details.callDirection == Call.Details.DIRECTION_INCOMING &&
            runCatching { spam.screenCall(details.handle?.schemeSpecificPart) }.getOrDefault(false)
        val response = CallResponse.Builder().apply {
            if (block) setDisallowCall(true).setRejectCall(true).setSkipNotification(true)
        }.build()
        respondToCall(details, response)
    }
}
