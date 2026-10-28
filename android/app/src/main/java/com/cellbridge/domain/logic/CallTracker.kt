package com.cellbridge.domain.logic

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.domain.model.EndReason

/**
 * Turns telecom call snapshots into [CallEvent]s.
 *
 * - Repeated snapshots with an unchanged status produce nothing.
 * - HOLDING <-> ACTIVE after the call was answered produce nothing.
 * - An incoming call DISCONNECTED without ever having been ACTIVE ended "rejected" if the platform says
 *   this side declined it, otherwise "missed".
 * - A DISCONNECTED snapshot for a call we never saw is ignored.
 *
 * Pure Kotlin. Not thread-safe: callers serialize access.
 */
class CallTracker {
    private class Entry(var snapshot: CallSnapshot, var answered: Boolean)

    private val calls = LinkedHashMap<String, Entry>()

    /** Latest snapshot of every call that has not yet disconnected. */
    val liveCalls: List<CallSnapshot> get() = calls.values.map { it.snapshot }

    fun onUpdate(call: CallSnapshot): CallEvent? {
        val known = calls[call.id]

        if (call.status == CallStatus.DISCONNECTED) {
            calls.remove(call.id)
            return known?.let { CallEvent.Ended(call, endReason(call, it.answered)) }
        }

        if (known == null) {
            calls[call.id] = Entry(call, answered = call.status == CallStatus.ACTIVE)
            return when {
                call.status == CallStatus.ACTIVE -> CallEvent.Answered(call)
                call.direction == CallDirection.INCOMING -> CallEvent.Ringing(call)
                else -> CallEvent.Dialing(call)
            }
        }

        val statusChanged = known.snapshot.status != call.status
        known.snapshot = call
        if (!statusChanged) return null
        if (call.status == CallStatus.ACTIVE && !known.answered) {
            known.answered = true
            return CallEvent.Answered(call)
        }
        return null
    }

    private fun endReason(call: CallSnapshot, answered: Boolean): EndReason? = when {
        call.direction != CallDirection.INCOMING || answered -> null
        call.rejected -> EndReason.REJECTED
        else -> EndReason.MISSED
    }
}
