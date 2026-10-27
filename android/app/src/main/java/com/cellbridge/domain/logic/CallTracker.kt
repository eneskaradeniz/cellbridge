package com.cellbridge.domain.logic

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus

/**
 * Turns telecom call snapshots into [CallEvent]s.
 *
 * - Repeated snapshots with an unchanged status produce nothing.
 * - HOLDING <-> ACTIVE after the call was answered produce nothing.
 * - A call is "missed" when an incoming call is DISCONNECTED without ever having been ACTIVE.
 * - A DISCONNECTED snapshot for a call we never saw is ignored.
 *
 * Pure Kotlin. Not thread-safe: callers serialize access (telecom callbacks arrive on the main thread).
 */
class CallTracker {
    private class Entry(var status: CallStatus, var answered: Boolean)

    private val calls = LinkedHashMap<String, Entry>()

    /** True while any call has not yet disconnected. */
    val hasLiveCalls: Boolean get() = calls.isNotEmpty()

    fun onUpdate(call: CallSnapshot): CallEvent? {
        val known = calls[call.id]

        if (call.status == CallStatus.DISCONNECTED) {
            calls.remove(call.id)
            return known?.let { CallEvent.Ended(call, missed = call.direction == CallDirection.INCOMING && !it.answered) }
        }

        if (known == null) {
            calls[call.id] = Entry(call.status, answered = call.status == CallStatus.ACTIVE)
            return when {
                call.status == CallStatus.ACTIVE -> CallEvent.Answered(call)
                call.direction == CallDirection.INCOMING -> CallEvent.Ringing(call)
                else -> CallEvent.Dialing(call)
            }
        }

        if (known.status == call.status) return null
        known.status = call.status
        if (call.status == CallStatus.ACTIVE && !known.answered) {
            known.answered = true
            return CallEvent.Answered(call)
        }
        return null
    }
}
