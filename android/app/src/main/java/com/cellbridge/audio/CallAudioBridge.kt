package com.cellbridge.audio

import android.util.Log
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Turns "the client will take call X's audio at this UDP address" plus the call's lifecycle into daemon
 * start/stop: audio flows until the call ends, starting when the call is answered, or at once for an outgoing call: while it dials
 * the network plays ringback and busy tones to the caller, and they have to reach the iPhone too.
 */
@Singleton
class CallAudioBridge @Inject constructor(
    private val feed: CallFeed,
    private val audio: CallAudio,
) {
    private val peers = ConcurrentHashMap<String, InetSocketAddress>()
    private var job: Job? = null
    private var scope: CoroutineScope? = null
    private val _bridged = MutableStateFlow<Set<String>>(emptySet())

    /** Calls whose audio is flowing to the client right now; the phone's own call screen shows "on the iPhone" for them. */
    val bridged: StateFlow<Set<String>> = _bridged.asStateFlow()

    @Synchronized
    fun start(scope: CoroutineScope) {
        job?.cancel()
        this.scope = scope
        job = scope.launch { feed.events.collect { runCatching { onEvent(it) }.onFailure { Log.e(TAG, "audio bridge", it) } } }
    }

    @Synchronized
    fun stop() {
        job?.cancel()
        job = null
    }

    suspend fun isAvailable(): Boolean = audio.isAvailable()

    /** Call before answering, so the answer's `Answered` event finds the peer. */
    fun expect(callId: String, peer: InetSocketAddress) {
        peers[callId] = peer
        // The call may already be dialing (the `Dialing` event came before the client's peer was known).
        scope?.launch {
            if (feed.liveCalls().any { it.id == callId && it.direction == CallDirection.OUTGOING && it.status == CallStatus.DIALING }) relay(callId, peer)
        }
    }

    /** Starts the relay for [id] unless it already runs (the answer must not restart what dialing began). */
    private suspend fun relay(id: String, peer: InetSocketAddress) {
        if (id in _bridged.value) return
        if (audio.start(peer)) _bridged.update { it + id } else Log.w(TAG, "audio daemon did not start (id=$id)")
    }

    fun forget(callId: String) {
        peers.remove(callId)
    }

    /** Transfer to the phone: stops the relay for [callId] (the call goes on on the phone's own audio). False if it was not relayed. */
    suspend fun release(callId: String): Boolean {
        if (peers.remove(callId) == null) return false
        audio.stop()
        _bridged.update { it - callId }
        return true
    }

    /** Transfer to the client: starts the relay for a call that is already active. */
    suspend fun attach(callId: String, peer: InetSocketAddress): Boolean {
        if (feed.liveCalls().none { it.id == callId && it.status == CallStatus.ACTIVE }) return false
        peers[callId] = peer
        val started = audio.start(peer)
        if (started) _bridged.update { it + callId } else peers.remove(callId)
        return started
    }

    private suspend fun onEvent(event: CallEvent) {
        val id = event.call.id
        when (event) {
            is CallEvent.Answered, is CallEvent.Dialing -> peers[id]?.let { relay(id, it) }
            is CallEvent.Ended -> {
                _bridged.update { it - id }
                if (peers.remove(id) != null) audio.stop()
            }
            is CallEvent.Ringing -> Unit
        }
    }

    private companion object {
        const val TAG = "CellBridge"
    }
}
