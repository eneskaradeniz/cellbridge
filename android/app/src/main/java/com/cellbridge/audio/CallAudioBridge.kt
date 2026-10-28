package com.cellbridge.audio

import android.util.Log
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Turns "the client will take call X's audio at this UDP address" plus the call's lifecycle into daemon
 * start/stop: audio flows from the moment the call is really answered until it ends.
 */
@Singleton
class CallAudioBridge @Inject constructor(
    private val feed: CallFeed,
    private val audio: CallAudio,
) {
    private val peers = ConcurrentHashMap<String, InetSocketAddress>()
    private var job: Job? = null

    @Synchronized
    fun start(scope: CoroutineScope) {
        job?.cancel()
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
    }

    fun forget(callId: String) {
        peers.remove(callId)
    }

    private suspend fun onEvent(event: CallEvent) {
        val id = event.call.id
        when (event) {
            is CallEvent.Answered -> peers[id]?.let { if (!audio.start(it)) Log.w(TAG, "audio daemon did not start (id=$id)") }
            is CallEvent.Ended -> if (peers.remove(id) != null) audio.stop()
            is CallEvent.Ringing, is CallEvent.Dialing -> Unit
        }
    }

    private companion object {
        const val TAG = "CellBridge"
    }
}
