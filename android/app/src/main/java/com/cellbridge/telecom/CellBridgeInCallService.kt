package com.cellbridge.telecom

import android.telecom.Call
import android.telecom.InCallService
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import dagger.hilt.android.AndroidEntryPoint
import java.util.UUID
import javax.inject.Inject

/** Bound by Telecom while this app is the default dialer; reports every call to [CallRepository]. */
@AndroidEntryPoint
class CellBridgeInCallService : InCallService() {
    @Inject lateinit var repository: CallRepository
    @Inject lateinit var wakeLock: CallWakeLock

    private val ids = HashMap<Call, String>()

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) = report(call, state)
    }

    override fun onCallAdded(call: Call) {
        ids[call] = UUID.randomUUID().toString()
        call.registerCallback(callback)
        report(call, stateOf(call))
    }

    override fun onCallRemoved(call: Call) {
        call.unregisterCallback(callback)
        report(call, Call.STATE_DISCONNECTED) // no-op if already reported
        ids.remove(call)
    }

    override fun onDestroy() {
        wakeLock.setHeld(false)
        super.onDestroy()
    }

    private fun report(call: Call, state: Int) {
        val id = ids[call] ?: return
        val status = statusOf(state) ?: return
        val direction = if (call.details.callDirection == Call.Details.DIRECTION_INCOMING) {
            CallDirection.INCOMING
        } else {
            CallDirection.OUTGOING
        }
        val number = call.details.handle?.schemeSpecificPart?.takeIf { it.isNotBlank() }
        repository.onCallUpdate(CallSnapshot(id, number, direction, status))
        wakeLock.setHeld(repository.hasLiveCalls)
    }

    @Suppress("DEPRECATION") // Call.Details.getState() needs API 31; minSdk is 29.
    private fun stateOf(call: Call): Int = call.state

    private fun statusOf(state: Int): CallStatus? = when (state) {
        Call.STATE_RINGING -> CallStatus.RINGING
        Call.STATE_NEW, Call.STATE_DIALING, Call.STATE_CONNECTING, Call.STATE_PULLING_CALL,
        Call.STATE_SELECT_PHONE_ACCOUNT -> CallStatus.DIALING
        Call.STATE_ACTIVE -> CallStatus.ACTIVE
        Call.STATE_HOLDING -> CallStatus.HOLDING
        Call.STATE_DISCONNECTED -> CallStatus.DISCONNECTED
        else -> null // DISCONNECTING: wait for DISCONNECTED
    }
}
