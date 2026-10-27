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

/** Read side of the call state, as the control server sees it. */
interface CallFeed {
    val events: SharedFlow<CallEvent>

    /** Calls that have not yet disconnected. */
    fun liveCalls(): List<CallSnapshot>
}

/**
 * Process-wide call state: the InCallService feeds it (main thread), the control server reads it
 * (Ktor threads), so the tracker is guarded by this object's lock.
 */
@Singleton
class CallRepository @Inject constructor() : CallFeed {
    private val tracker = CallTracker()
    private val _events = MutableSharedFlow<CallEvent>(extraBufferCapacity = 16)

    override val events: SharedFlow<CallEvent> = _events.asSharedFlow()

    @Synchronized
    override fun liveCalls(): List<CallSnapshot> = tracker.liveCalls

    @Synchronized
    fun onCallUpdate(call: CallSnapshot) {
        tracker.onUpdate(call)?.let {
            Log.i(TAG, "${it::class.simpleName} id=${it.call.id} status=${it.call.status}") // never log the number
            check(_events.tryEmit(it)) { "call event buffer full" }
        }
    }

    val hasLiveCalls: Boolean @Synchronized get() = tracker.liveCalls.isNotEmpty()

    private companion object {
        const val TAG = "CellBridge"
    }
}
