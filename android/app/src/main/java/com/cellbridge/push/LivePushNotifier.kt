package com.cellbridge.push

import android.util.Log
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

/** What the control server needs of the Live Activity pushes: the tokens the client sends. */
interface LiveRegistry {
    fun startToken(token: String)
    suspend fun updateToken(callId: String, token: String)
}

object NoLive : LiveRegistry {
    override fun startToken(token: String) = Unit
    override suspend fun updateToken(callId: String, token: String) = Unit
}

/**
 * Keeps the iPhone's Live Activity in step with the calls that run on the phone itself (docs/protocol.md): `start` when a call
 * becomes active or held without a client relaying it, `update` when its status changes, `end` when it hangs up or a client takes
 * it over. Only a push can start an activity while the app is in the background; `update` and `end` need the update token the
 * client reports for that call, so they wait for it.
 */
@Singleton
class LivePushNotifier @Inject constructor(
    private val feed: CallFeed,
    private val store: PushStore,
    private val apns: PushNotifier,
) : LiveRegistry {
    private val lock = Mutex()
    private var startToken: String? = null
    private var bridgedNow: () -> Set<String> = { emptySet() }
    private val started = mutableMapOf<String, Long>() // callId -> when its start push went out
    private val sentStatus = mutableMapOf<String, String>()
    private val lastSeen = mutableMapOf<String, CallSnapshot>()
    private val updateTokens = mutableMapOf<String, String>()

    /** [bridged] are the calls a client relays; they are not on the phone, so they get no activity. */
    fun start(scope: CoroutineScope, bridged: StateFlow<Set<String>>) {
        bridgedNow = { bridged.value }
        scope.launch {
            merge(feed.events.map { }, bridged.map { }).collect {
                runCatching { reconcile() }.onFailure { Log.w(TAG, "live push failed", it) }
            }
        }
    }

    override fun startToken(token: String) {
        startToken = token
        store.load()?.let { store.save(it.withLiveStart(token)) }
    }

    override suspend fun updateToken(callId: String, token: String) {
        lock.withLock { updateTokens[callId] = token }
        runCatching { reconcile() }.onFailure { Log.w(TAG, "live push failed", it) }
    }

    internal suspend fun reconcile() = lock.withLock {
        val target = store.load() ?: return@withLock
        val topic = target.alertTopic?.let { "$it.push-type.liveactivity" } ?: return@withLock
        if (!apns.available()) return@withLock
        val now = apns.nowMs()
        val bridged = bridgedNow()
        val wanted = feed.liveCalls()
            .filter { (it.status == CallStatus.ACTIVE || it.status == CallStatus.HOLDING) && it.id !in bridged }
            .associateBy { it.id }

        for ((id, at) in started.entries.toList()) if (now - at > STALE_MS) forget(id) // its end never got through; the stale date took it
        val begin = startToken ?: target.liveStartToken
        if (begin != null) {
            for ((id, call) in wanted) {
                if (id in started) continue
                val status = send(target, begin, topic, "start", call, now)
                if (status in 200..299) { started[id] = now; sentStatus[id] = call.status.name.lowercase(); lastSeen[id] = call }
                else if (status == 410 || status == 400) { startToken = null; store.save(target.withLiveStart(null)) } // the start token is no good
            }
        }
        for (id in started.keys.toList()) {
            val token = updateTokens[id] ?: continue // update and end wait for the client to report this activity's token
            val call = wanted[id]
            if (call == null) {
                if (send(target, token, topic, "end", lastSeen.getValue(id), now) in 200..299) forget(id)
            } else {
                lastSeen[id] = call
                val status = call.status.name.lowercase()
                if (sentStatus[id] != status && send(target, token, topic, "update", call, now) in 200..299) sentStatus[id] = status
            }
        }
    }

    private fun forget(id: String) {
        started.remove(id); sentStatus.remove(id); lastSeen.remove(id); updateTokens.remove(id)
    }

    private suspend fun send(target: PushTarget, deviceToken: String, topic: String, event: String, call: CallSnapshot, now: Long): Int? {
        val plain = buildJsonObject { call.number?.let { put("number", it) } }.toString().toByteArray()
        val state = buildJsonObject {
            put("status", call.status.name.lowercase())
            put("connectedAtMs", call.connectedAtMs.takeIf { it > 0 } ?: now)
            put("outgoing", call.direction == CallDirection.OUTGOING)
            put("sealed", PushCrypto.seal(target.key, plain))
        }
        val seconds = now / 1000
        val aps = buildJsonObject {
            put("timestamp", seconds)
            put("event", event)
            put("content-state", state)
            put("stale-date", seconds + STALE_MS / 1000)
            if (event == "end") put("dismissal-date", seconds)
            if (event == "start") {
                // ActivityKit refuses a start without a complete alert ("Received start without an alert configuration" in the iPhone's log):
                // it needs a title and a body. `loc-key` is the app's own string for the body, in the phone's language.
                put("alert", buildJsonObject {
                    put("title", "CellBridge")
                    put("body", "On the phone")
                    put("loc-key", "On the phone")
                })
                put("attributes-type", "CallActivityAttributes")
                put("attributes", buildJsonObject { put("callId", call.id) })
            }
        }
        val body = JsonObject(mapOf("aps" to aps)).toString().toByteArray()
        val status = apns.post(target, deviceToken, "liveactivity", topic, emptyMap(), 60, body)
        // Never log a token, the number or the key. How long ago Telecom says the call connected tells whether the timer is right.
        Log.i(TAG, "live $event for call ${call.id}: HTTP $status, connected ${if (call.connectedAtMs > 0) (now - call.connectedAtMs) / 1000 else -1} s ago")
        return status
    }

    private companion object {
        const val TAG = "CellBridge"
        const val STALE_MS = 4 * 3600 * 1000L // an activity whose end never gets through goes away by itself
    }
}
