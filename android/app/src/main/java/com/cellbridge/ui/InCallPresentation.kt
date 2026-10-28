package com.cellbridge.ui

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus

enum class CallPhase { INCOMING, DIALING, ACTIVE, HOLDING }

/** The call the screen is about: a ringing one needs an answer first, then the one in progress, then the rest. */
fun primaryCall(calls: List<CallSnapshot>): CallSnapshot? =
    calls.firstOrNull { it.direction == CallDirection.INCOMING && it.status == CallStatus.RINGING }
        ?: calls.firstOrNull { it.status == CallStatus.ACTIVE }
        ?: calls.firstOrNull()

fun phaseOf(call: CallSnapshot): CallPhase = when (call.status) {
    CallStatus.RINGING -> CallPhase.INCOMING
    CallStatus.DIALING -> CallPhase.DIALING
    CallStatus.HOLDING -> CallPhase.HOLDING
    CallStatus.ACTIVE, CallStatus.DISCONNECTED -> CallPhase.ACTIVE
}

/** mm:ss, or h:mm:ss once past the hour. */
fun formatElapsed(millis: Long): String {
    val total = (millis / 1000).coerceAtLeast(0)
    val seconds = total % 60
    val minutes = total / 60 % 60
    val hours = total / 3600
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, seconds) else "%d:%02d".format(minutes, seconds)
}
