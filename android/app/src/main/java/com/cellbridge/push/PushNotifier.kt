package com.cellbridge.push

import android.util.Log
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.server.ClientPresence
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

/** What the control server needs of push: remember the client's token, say whether pushes can be sent at all. */
interface PushRegistry {
    fun available(): Boolean
    fun register(target: PushTarget)
}

object NoPush : PushRegistry {
    override fun available() = false
    override fun register(target: PushTarget) = Unit
}

/**
 * Starts the iPhone's app when a call rings and the app is not there to hear it (docs/protocol.md): a VoIP push through
 * APNs, sealed under the key the two phones share. With a client connected the control channel is faster, but it may be a
 * dead socket, so a push follows after a short wait if the call is still ringing.
 */
@Singleton
class PushNotifier @Inject constructor(
    private val feed: CallFeed,
    private val store: PushStore,
    private val credentials: ApnsCredentialSource,
    private val transport: ApnsTransport,
    private val presence: ClientPresence,
) : PushRegistry {
    internal var nowMs: () -> Long = { System.currentTimeMillis() }
    private var jwt: Pair<Long, String>? = null

    override fun available() = credentials.load() != null

    override fun register(target: PushTarget) = store.save(target)

    /** The iPhone has registered its push token. */
    fun hasToken() = store.load() != null

    fun start(scope: CoroutineScope) {
        scope.launch {
            feed.events.filterIsInstance<CallEvent.Ringing>().collect { event ->
                if (event.call.direction != CallDirection.INCOMING) return@collect
                scope.launch { runCatching { onRinging(event.call.id, event.call.number) }.onFailure { Log.w(TAG, "push failed", it) } }
            }
        }
    }

    internal suspend fun onRinging(callId: String, number: String?) {
        if (!available() || store.load() == null) return
        if (presence.connected) {
            delay(CONNECTED_WAIT_MS)
            if (feed.liveCalls().none { it.id == callId && it.status == CallStatus.RINGING }) return
        }
        push(callId, number)
    }

    private suspend fun push(callId: String, number: String?) {
        val target = store.load() ?: return
        val creds = credentials.load() ?: return
        val now = nowMs()
        val token = jwt?.takeIf { now - it.first < JWT_LIFETIME_MS }?.second
            ?: ApnsJwt.create(creds.keyId, creds.teamId, creds.key, now / 1000).also { jwt = now to it }
        val plain = buildJsonObject {
            put("callId", callId)
            number?.let { put("number", it) }
        }.toString().toByteArray()
        val body = buildJsonObject { put("cb", PushCrypto.seal(target.key, plain)) }.toString().toByteArray()
        val host = if (target.sandbox) "api.sandbox.push.apple.com" else "api.push.apple.com"
        val status = transport.post(
            host, "/3/device/${target.token}",
            mapOf(
                "authorization" to "bearer $token", "apns-push-type" to "voip", "apns-topic" to target.topic,
                "apns-priority" to "10", "apns-expiration" to (now / 1000 + EXPIRY_SECONDS).toString(),
            ),
            body,
        )
        Log.i(TAG, "push for call $callId: HTTP $status") // never log the token, the number or the key
        when (status) {
            410 -> store.clear() // the token is no longer valid
            403 -> jwt = null // the provider token was refused: sign a fresh one next time
        }
    }

    private companion object {
        const val TAG = "CellBridge"
        const val CONNECTED_WAIT_MS = 3_000L
        const val JWT_LIFETIME_MS = 40 * 60 * 1000L // APNs wants a token between 20 and 60 minutes old
        const val EXPIRY_SECONDS = 20L // a call that rang out is not worth delivering late
    }
}
