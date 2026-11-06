package com.cellbridge.push

import android.util.Log
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.server.ClientPresence
import com.cellbridge.sms.SmsGateway
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
 * Reaches the iPhone when its app is not there to hear (docs/protocol.md). A ringing call gets a VoIP push through APNs, a
 * received text an ordinary alert push; both are sealed under the key the two phones share. With a client connected the control
 * channel is faster, but it may be a dead socket, so a push follows after a short wait if the call still rings or the text is
 * still unacknowledged.
 */
@Singleton
class PushNotifier @Inject constructor(
    private val feed: CallFeed,
    private val store: PushStore,
    private val credentials: ApnsCredentialSource,
    private val transport: ApnsTransport,
    private val presence: ClientPresence,
    private val sms: SmsGateway,
) : PushRegistry {
    internal var nowMs: () -> Long = { System.currentTimeMillis() }
    private var jwt: Pair<Long, String>? = null

    override fun available() = credentials.load() != null

    override fun register(target: PushTarget) {
        // The live token travels in its own message and may have come first: a fresh push_token must not forget it.
        val kept = store.load()?.liveStartToken
        store.save(if (target.liveStartToken == null && kept != null) target.withLiveStart(kept) else target)
    }

    /** The iPhone has registered its push token. */
    fun hasToken() = store.load() != null

    fun start(scope: CoroutineScope) {
        scope.launch {
            feed.events.filterIsInstance<CallEvent.Ringing>().collect { event ->
                if (event.call.direction != CallDirection.INCOMING) return@collect
                scope.launch { runCatching { onRinging(event.call.id, event.call.number) }.onFailure { Log.w(TAG, "push failed", it) } }
            }
        }
        scope.launch {
            sms.incoming.collect { text ->
                scope.launch { runCatching { onSms(text) }.onFailure { Log.w(TAG, "text push failed", it) } }
            }
        }
    }

    /** A text arrived: pushes it unless the client takes it over the control channel (it acknowledges what it stored). */
    internal suspend fun onSms(text: IncomingSms) {
        val target = store.load() ?: return
        if (!available() || target.alertToken == null) return
        if (presence.connected) {
            delay(SMS_WAIT_MS)
            if (sms.unacknowledged().none { it.id == text.id }) return
        }
        val plain = buildJsonObject {
            put("id", text.id.toString())
            put("from", text.from)
            put("body", text.body.take(MAX_PUSH_BODY))
            put("ts", text.timestamp)
        }.toString().toByteArray()
        val aps = buildJsonObject {
            put("alert", buildJsonObject { put("title-loc-key", "NEW_MESSAGE") }) // the app's strings; the extension replaces it
            put("mutable-content", 1)
            put("sound", "default")
        }
        val body = buildJsonObject { put("aps", aps); put("cb", PushCrypto.seal(target.key, plain)) }.toString().toByteArray()
        val status = post(
            target, target.alertToken, "alert", target.alertTopic ?: return,
            mapOf("apns-collapse-id" to "sms-${text.id}"), EXPIRY_TEXT_SECONDS, body,
        )
        Log.i(TAG, "push for text ${text.id}: HTTP $status") // never log the token, the number, the text or the key
        if (status == 410) store.save(target.withoutAlert())
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
        val plain = buildJsonObject {
            put("callId", callId)
            number?.let { put("number", it) }
        }.toString().toByteArray()
        val body = buildJsonObject { put("cb", PushCrypto.seal(target.key, plain)) }.toString().toByteArray()
        val status = post(target, target.token, "voip", target.topic, emptyMap(), EXPIRY_SECONDS, body) ?: return
        Log.i(TAG, "push for call $callId: HTTP $status") // never log the token, the number or the key
        if (status == 410) store.clear() // the token is no longer valid
    }

    /** One APNs request; null when there is no key to sign it with. A refused provider token is dropped so the next call signs a fresh one. */
    internal suspend fun post(
        target: PushTarget, deviceToken: String, type: String, topic: String, extra: Map<String, String>, expirySeconds: Long, body: ByteArray,
    ): Int? {
        val creds = credentials.load() ?: return null
        val now = nowMs()
        val token = jwt?.takeIf { now - it.first < JWT_LIFETIME_MS }?.second
            ?: ApnsJwt.create(creds.keyId, creds.teamId, creds.key, now / 1000).also { jwt = now to it }
        val host = if (target.sandbox) "api.sandbox.push.apple.com" else "api.push.apple.com"
        val status = transport.post(
            host, "/3/device/$deviceToken",
            mapOf(
                "authorization" to "bearer $token", "apns-push-type" to type, "apns-topic" to topic,
                "apns-priority" to "10", "apns-expiration" to (now / 1000 + expirySeconds).toString(),
            ) + extra,
            body,
        )
        if (status == 403) jwt = null
        return status
    }

    private companion object {
        const val TAG = "CellBridge"
        const val CONNECTED_WAIT_MS = 3_000L
        const val JWT_LIFETIME_MS = 40 * 60 * 1000L // APNs wants a token between 20 and 60 minutes old
        const val EXPIRY_SECONDS = 20L // a call that rang out is not worth delivering late
        const val EXPIRY_TEXT_SECONDS = 24 * 3600L // a text is worth delivering when the iPhone comes back online
        const val SMS_WAIT_MS = 10_000L // how long a connected client has to acknowledge a text before it is pushed
        const val MAX_PUSH_BODY = 500 // characters; APNs allows 4 KB for the whole sealed payload
    }
}
