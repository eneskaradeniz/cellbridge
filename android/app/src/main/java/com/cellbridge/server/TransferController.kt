package com.cellbridge.server

import com.cellbridge.audio.CallAudioBridge
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Moves a call between the phone and the iPhone; the control server tells the client. Nothing on the phone starts [toIphone] any more
 * (it has no call screen of its own); the iPhone's take-over button is meant to, and is not built yet.
 */
@Singleton
class TransferController @Inject constructor(
    private val presence: ClientPresence,
    private val audio: CallAudioBridge,
) {
    private val _offers = MutableSharedFlow<String>(extraBufferCapacity = 4)
    private val _takeBacks = MutableSharedFlow<String>(extraBufferCapacity = 4)

    /** "Transfer to iPhone" pressed: each becomes a `transfer_offer`. */
    val offers: SharedFlow<String> = _offers.asSharedFlow()

    /** "Take it here" pressed: each becomes an unsolicited `transfer_result`, which makes the client end its side quietly. */
    val takeBacks: SharedFlow<String> = _takeBacks.asSharedFlow()

    /** False when no client is connected to take the call. */
    fun toIphone(callId: String): Boolean = presence.connected && _offers.tryEmit(callId)

    /** Stops the relay for [callId]; the call goes on on the phone. False if it was not on the iPhone. */
    suspend fun toPhone(callId: String): Boolean {
        if (!audio.release(callId)) return false
        _takeBacks.tryEmit(callId)
        return true
    }
}
