package com.cellbridge.telecom

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.TelecomManager
import android.telephony.PhoneNumberUtils
import android.util.Log
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import javax.inject.Inject

sealed interface DialOutcome {
    data class Placed(val callId: String) : DialOutcome
    data class Failed(val error: String) : DialOutcome
}

/** Starts calls on the host; what the control server needs of the telephony side. */
interface CallDialer {
    suspend fun dial(number: String): DialOutcome
}

/** The two platform facts [OutgoingCalls] depends on, so the rules can be tested without a phone. */
interface TelecomPlacer {
    fun isEmergency(number: String): Boolean

    /** Hands the call to Telecom; throws if the platform refuses (missing permission / role). */
    fun place(number: String)
}

class PlatformTelecom @Inject constructor(@ApplicationContext private val context: Context) : TelecomPlacer {
    override fun isEmergency(number: String) = PhoneNumberUtils.isEmergencyNumber(number)

    override fun place(number: String) {
        context.getSystemService(TelecomManager::class.java).placeCall(Uri.fromParts("tel", number, null), Bundle())
    }
}

/**
 * Places one outgoing call at a time and reports the id the call gets once Telecom has it. Only plain phone numbers
 * are dialed (no `*`/`#` service codes) and never an emergency number: the bridge is not a safe way to reach 112.
 */
class OutgoingCalls @Inject constructor(
    private val feed: CallFeed,
    private val telecom: TelecomPlacer,
) : CallDialer {
    private val lock = Mutex()
    internal var startTimeoutMs = 10_000L

    override suspend fun dial(number: String): DialOutcome {
        val plain = number.filter { it !in " ()-" }
        if (!PLAIN_NUMBER.matches(plain)) return DialOutcome.Failed("invalid")
        if (telecom.isEmergency(plain)) return DialOutcome.Failed("emergency")
        return lock.withLock {
            if (feed.liveCalls().any { it.direction == CallDirection.OUTGOING }) return DialOutcome.Failed("busy")
            place(plain)
        }
    }

    private suspend fun place(number: String): DialOutcome = coroutineScope {
        // Subscribe before placing: Dialing can arrive before placeCall returns.
        val dialing = async(start = CoroutineStart.UNDISPATCHED) {
            withTimeout(startTimeoutMs) { feed.events.filterIsInstance<CallEvent.Dialing>().first() }
        }
        try {
            telecom.place(number)
            DialOutcome.Placed(dialing.await().call.id)
        } catch (e: Exception) {
            dialing.cancel()
            Log.w(TAG, "dial failed: ${e::class.simpleName}") // never log the number
            DialOutcome.Failed("failed")
        }
    }

    private companion object {
        const val TAG = "CellBridge"
        val PLAIN_NUMBER = Regex("""\+?[0-9]{3,20}""")
    }
}
