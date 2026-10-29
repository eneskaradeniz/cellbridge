package com.cellbridge.server

import android.util.Log
import com.cellbridge.audio.CallAudioBridge
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import com.cellbridge.history.HistorySource
import com.cellbridge.history.NoHistory
import com.cellbridge.push.NoPush
import com.cellbridge.push.PushNotifier
import com.cellbridge.push.PushRegistry
import com.cellbridge.push.PushTarget
import com.cellbridge.sms.SmsGateway
import com.cellbridge.telecom.CallDialer
import com.cellbridge.telecom.DialOutcome
import com.cellbridge.protocol.CallLogItem
import com.cellbridge.protocol.ClientMessage
import com.cellbridge.protocol.SmsHistoryItem
import com.cellbridge.protocol.PROTOCOL_VERSION
import com.cellbridge.protocol.ServerMessage
import com.cellbridge.protocol.decodeClientMessage
import com.cellbridge.protocol.encode
import com.cellbridge.telecom.CallCommands
import com.cellbridge.telecom.CallFeed
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.application.serverConfig
import io.ktor.server.routing.routing
import io.ktor.server.websocket.DefaultWebSocketServerSession
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.pingPeriod
import io.ktor.server.websocket.timeout
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readText
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

const val CONTROL_PORT = 8765

/** Hosts the control channel (docs/protocol.md) for the lifetime of the process. */
@Singleton
class ControlServer @Inject constructor(
    private val feed: CallFeed,
    private val commands: CallCommands,
    private val audio: CallAudioBridge,
    private val sms: SmsGateway,
    private val dialer: CallDialer,
    private val pairingToken: PairingToken,
    private val history: HistorySource,
    private val push: PushNotifier,
    private val presence: ClientPresence,
    private val transfers: TransferController,
) {
    private var engine: EmbeddedServer<*, *>? = null
    private val _running = MutableStateFlow(false)
    private var scope: CoroutineScope? = null

    /** True while the server is listening; false before start, after stop, and when binding failed. */
    val running: StateFlow<Boolean> = _running.asStateFlow()

    @Synchronized
    fun start() {
        if (engine != null) return
        // Binding happens in a Ktor coroutine after start() returns, so a failure there (port in use) would
        // reach the default handler and kill the process. Route it here instead.
        val onFailure = CoroutineExceptionHandler { _, error ->
            Log.e(TAG, "control server failed", error)
            _running.value = false
        }
        runCatching {
            embeddedServer(
                CIO,
                rootConfig = serverConfig {
                    parentCoroutineContext = onFailure
                    module { controlModule(feed, commands, audio, sms, dialer, pairingToken.value, capabilities = ::capabilities, history = history, push = push, presence = presence, transfers = transfers) }
                },
                configure = { connector { port = CONTROL_PORT; host = "0.0.0.0" } },
            ).also { server ->
                server.start(wait = false)
                runBlocking { withTimeout(BIND_TIMEOUT_MS) { server.engine.resolvedConnectors() } } // throws if the bind failed
            }
        }.onSuccess {
            engine = it
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default).also { audio.start(it); push.start(it) }
            _running.value = true
        }.onFailure { Log.e(TAG, "control server failed to start", it) }
    }

    @Synchronized
    fun stop() {
        audio.stop()
        scope?.cancel()
        scope = null
        engine?.stop(gracePeriodMillis = 500, timeoutMillis = 1_000)
        engine = null
        _running.value = false
    }

    /** `audio` only while the root daemon answers; otherwise the host runs control-only (docs/protocol.md). */
    private suspend fun capabilities(): List<String> = buildList {
        add("calls")
        if (sms.isAvailable()) add("sms")
        if (audio.isAvailable()) add("audio")
        if (history.callsAvailable()) add("calllog")
        if (sms.isAvailable()) add("smshistory")
        if (push.available()) add("push")
        if (audio.isAvailable()) add("transfer")
    }

    private companion object {
        const val TAG = "CellBridge"
        const val BIND_TIMEOUT_MS = 5_000L
    }
}

/** The protocol itself, separate from the engine so tests can run it without sockets. */
fun Application.controlModule(
    feed: CallFeed,
    commands: CallCommands,
    audio: CallAudioBridge,
    sms: SmsGateway,
    dialer: CallDialer,
    token: String,
    capabilities: suspend () -> List<String>,
    authFailureDelay: Duration = 1.seconds,
    history: HistorySource = NoHistory,
    push: PushRegistry = NoPush,
    presence: ClientPresence = ClientPresence(),
    transfers: TransferController = TransferController(presence, audio),
) {
    install(WebSockets) {
        pingPeriod = 10.seconds
        timeout = 15.seconds
        maxFrameSize = MAX_FRAME_BYTES
    }
    routing {
        webSocket("/") { Session(this, feed, commands, audio, sms, dialer, token, capabilities, authFailureDelay, history, push, presence, transfers).run() }
    }
}

private const val MAX_FRAME_BYTES = 64L * 1024
private const val CALL_LOG_LIMIT = 300
private const val SMS_HISTORY_LIMIT = 500
private const val HISTORY_DAYS = 90L
private const val DAY_MS = 24L * 60 * 60 * 1000

private class Session(
    private val ws: DefaultWebSocketServerSession,
    private val feed: CallFeed,
    private val commands: CallCommands,
    private val audio: CallAudioBridge,
    private val sms: SmsGateway,
    private val dialer: CallDialer,
    private val token: String,
    private val capabilities: suspend () -> List<String>,
    private val authFailureDelay: Duration,
    private val history: HistorySource,
    private val push: PushRegistry,
    private val presence: ClientPresence,
    private val transfers: TransferController,
) {
    suspend fun run() {
        val hello = ws.incoming.receive().let { (it as? Frame.Text)?.readText() }?.let(::decodeClientMessage)
        if (hello !is ClientMessage.Hello) return reject("expected_hello")
        if (hello.version != PROTOCOL_VERSION) return reject("unsupported_version")
        if (!tokenMatches(hello.token)) {
            delay(authFailureDelay) // slows down guessing; the token is only 8 characters
            return reject("unauthorized")
        }

        coroutineScope {
            val acked = CompletableDeferred<Unit>()
            // Subscribe before acking so no event is missed, but hold events back until the ack is out.
            val forwarder = launch(start = CoroutineStart.UNDISPATCHED) {
                feed.events.collect { event ->
                    acked.await()
                    event.toMessage()?.let { send(it) }
                }
            }
            val offerForwarder = launch(start = CoroutineStart.UNDISPATCHED) {
                transfers.offers.collect { callId ->
                    acked.await()
                    val call = feed.liveCalls().firstOrNull { it.id == callId }
                    send(ServerMessage.TransferOffer(callId, call?.number, call?.connectedAtMs?.takeIf { it > 0 }))
                }
            }
            val takeBackForwarder = launch(start = CoroutineStart.UNDISPATCHED) {
                transfers.takeBacks.collect { callId ->
                    acked.await()
                    send(ServerMessage.TransferResult(callId, ok = true))
                }
            }
            val smsForwarder = launch(start = CoroutineStart.UNDISPATCHED) {
                sms.incoming.collect {
                    acked.await()
                    send(it.toMessage())
                }
            }
            send(ServerMessage.HelloAck(PROTOCOL_VERSION, capabilities()))
            feed.liveCalls()
                .filter { it.direction == CallDirection.INCOMING && it.status == CallStatus.RINGING }
                .forEach { send(ServerMessage.Ring(it.id, it.number)) }
            // Texts the client has not acknowledged yet (it may have been offline); it dedupes by id.
            if (sms.isAvailable()) runCatching { sms.unacknowledged() }.getOrDefault(emptyList()).forEach { send(it.toMessage()) }
            acked.complete(Unit)

            presence.joined()
            try {
                for (frame in ws.incoming) {
                    if (frame is Frame.Text) handle(decodeClientMessage(frame.readText()), scope = this@coroutineScope)
                }
            } finally {
                presence.left()
                forwarder.cancel()
                offerForwarder.cancel()
                takeBackForwarder.cancel()
                smsForwarder.cancel()
            }
        }
    }

    private suspend fun handle(message: ClientMessage?, scope: CoroutineScope) {
        val (callId, accepted) = when (message) {
            is ClientMessage.Answer -> {
                // Register the audio peer first: the call's Answered event may arrive before answer() returns.
                audioPeer(message.udpPort)?.let { audio.expect(message.callId, it) }
                val accepted = commands.answer(message.callId)
                if (!accepted) audio.forget(message.callId)
                message.callId to accepted
            }
            is ClientMessage.Reject -> message.callId to commands.reject(message.callId)
            is ClientMessage.Hangup -> message.callId to commands.hangup(message.callId)
            is ClientMessage.TransferToHost -> {
                send(ServerMessage.TransferResult(message.callId, audio.release(message.callId)))
                return
            }
            is ClientMessage.TransferAccept -> {
                val peer = audioPeer(message.udpPort)
                if (peer == null || !audio.attach(message.callId, peer)) send(ServerMessage.Error("unknown_call", message.callId))
                return
            }
            is ClientMessage.RingAck -> {
                // The iPhone is ringing: the phone in the pocket can stop. Without this ack it keeps ringing, so a dead
                // connection never swallows a call.
                commands.silence(message.callId)
                return
            }
            is ClientMessage.Dial -> {
                // Placing a call takes a moment; keep reading frames meanwhile.
                scope.launch {
                    val reply = when (val outcome = dialer.dial(message.number)) {
                        is DialOutcome.Placed -> {
                            audioPeer(message.udpPort)?.let { audio.expect(outcome.callId, it) }
                            ServerMessage.DialResult(message.clientId, ok = true, callId = outcome.callId)
                        }
                        is DialOutcome.Failed -> ServerMessage.DialResult(message.clientId, ok = false, error = outcome.error)
                    }
                    send(reply)
                }
                return
            }
            is ClientMessage.SmsAck -> {
                message.id.toLongOrNull()?.let { sms.acknowledge(it) } ?: send(ServerMessage.Error("bad_message"))
                return
            }
            is ClientMessage.SmsSend -> {
                // Sending can take a while; keep reading frames (pings, acks) meanwhile.
                scope.launch {
                    val result = sms.send(message.to, message.body)
                    send(ServerMessage.SmsResult(message.clientId, result is SendResult.Sent, (result as? SendResult.Failed)?.error))
                }
                return
            }
            is ClientMessage.CallLogRequest -> {
                val entries = history.calls(message.after?.toLongOrNull() ?: 0, message.since ?: 0, CALL_LOG_LIMIT)
                send(ServerMessage.CallLog(entries.map { CallLogItem(it.id.toString(), it.number, it.name, it.kind, it.timestamp, it.durationSeconds) }))
                return
            }
            is ClientMessage.SmsHistoryRequest -> {
                val since = message.since ?: (System.currentTimeMillis() - HISTORY_DAYS * DAY_MS)
                val items = if (sms.isAvailable()) history.texts(since, SMS_HISTORY_LIMIT) else emptyList()
                send(ServerMessage.SmsHistory(items.map { SmsHistoryItem(it.id, it.peer, it.body, it.timestamp, if (it.outgoing) "out" else "in") }))
                return
            }
            is ClientMessage.PushToken -> {
                val key = runCatching { java.util.Base64.getDecoder().decode(message.key) }.getOrNull()
                if (!push.available() || key?.size != 32 || message.token.length < 32 || message.env !in setOf("sandbox", "production")) {
                    return send(ServerMessage.Error("bad_message"))
                }
                push.register(PushTarget(message.token, message.env == "sandbox", message.topic, key))
                return
            }
            is ClientMessage.Hello, null -> return send(ServerMessage.Error("bad_message"))
        }
        if (!accepted) send(ServerMessage.Error("unknown_call", callId))
    }

    /** The client's address as seen on this connection plus the UDP port it announced; null means no audio. */
    private fun audioPeer(udpPort: Int?): InetSocketAddress? {
        if (udpPort == null || udpPort !in 1..65535) return null
        val address = runCatching { InetAddress.getByName(ws.call.request.local.remoteAddress) }.getOrNull()
        return (address as? Inet4Address)?.let { InetSocketAddress(it, udpPort) }
    }

    private suspend fun reject(code: String) {
        send(ServerMessage.Error(code))
        ws.close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, code))
    }

    private suspend fun send(message: ServerMessage) = ws.send(Frame.Text(message.encode()))

    private fun tokenMatches(candidate: String): Boolean =
        MessageDigest.isEqual(candidate.toByteArray(), token.toByteArray())
}

private fun IncomingSms.toMessage() = ServerMessage.Sms(id.toString(), from, body, timestamp)

private fun CallEvent.toMessage(): ServerMessage? = when (this) {
    is CallEvent.Ringing -> ServerMessage.Ring(call.id, call.number)
    is CallEvent.Ended -> ServerMessage.Ended(call.id, reason = reason?.name?.lowercase())
    is CallEvent.Answered -> ServerMessage.Answered(call.id)
    is CallEvent.Dialing -> null
}
