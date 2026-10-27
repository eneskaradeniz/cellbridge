package com.cellbridge.telecom

import android.util.Log
import com.cellbridge.domain.logic.CallTracker
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Process-wide call state: the InCallService feeds it, the WebSocket server (next step) collects [events].
 * All calls come from the main thread (telecom callbacks), so the tracker needs no locking.
 */
@Singleton
class CallRepository @Inject constructor() {
    private val tracker = CallTracker()
    private val _events = MutableSharedFlow<CallEvent>(extraBufferCapacity = 16)

    val events: SharedFlow<CallEvent> = _events.asSharedFlow()
    val hasLiveCalls: Boolean get() = tracker.hasLiveCalls

    fun onCallUpdate(call: CallSnapshot) {
        tracker.onUpdate(call)?.let {
            Log.i(TAG, "${it::class.simpleName} id=${it.call.id} status=${it.call.status}") // never log the number
            check(_events.tryEmit(it)) { "call event buffer full" }
        }
    }

    private companion object {
        const val TAG = "CellBridge"
    }
}
