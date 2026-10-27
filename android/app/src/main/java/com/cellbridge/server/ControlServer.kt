package com.cellbridge.server

import android.util.Log
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.protocol.ClientMessage
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
import io.ktor.server.engine.embeddedServer
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
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
    private val pairingToken: PairingToken,
) {
    private var engine: EmbeddedServer<*, *>? = null

    @Synchronized
    fun start() {
        if (engine != null) return
        runCatching {
            embeddedServer(CIO, port = CONTROL_PORT, host = "0.0.0.0") {
                controlModule(feed, commands, pairingToken.value, capabilities = { listOf("calls") })
            }.start(wait = false)
        }.onSuccess { engine = it }
            .onFailure { Log.e(TAG, "control server failed to start", it) }
    }

    @Synchronized
    fun stop() {
        engine?.stop(gracePeriodMillis = 500, timeoutMillis = 1_000)
        engine = null
    }

    private companion object {
        const val TAG = "CellBridge"
    }
}

/** The protocol itself, separate from the engine so tests can run it without sockets. */
fun Application.controlModule(
    feed: CallFeed,
    commands: CallCommands,
    token: String,
    capabilities: () -> List<String>,
    authFailureDelay: Duration = 1.seconds,
) {
    install(WebSockets) {
        pingPeriod = 10.seconds
        timeout = 15.seconds
        maxFrameSize = MAX_FRAME_BYTES
    }
    routing {
        webSocket("/") { Session(this, feed, commands, token, capabilities, authFailureDelay).run() }
    }
}

private const val MAX_FRAME_BYTES = 64L * 1024

private class Session(
    private val ws: DefaultWebSocketServerSession,
    private val feed: CallFeed,
    private val commands: CallCommands,
    private val token: String,
    private val capabilities: () -> List<String>,
    private val authFailureDelay: Duration,
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
            send(ServerMessage.HelloAck(PROTOCOL_VERSION, capabilities()))
            feed.liveCalls()
                .filter { it.direction == CallDirection.INCOMING && it.status == CallStatus.RINGING }
                .forEach { send(ServerMessage.Ring(it.id, it.number)) }
            acked.complete(Unit)

            try {
                for (frame in ws.incoming) {
                    if (frame is Frame.Text) handle(decodeClientMessage(frame.readText()))
                }
            } finally {
                forwarder.cancel()
            }
        }
    }

    private suspend fun handle(message: ClientMessage?) {
        val (callId, accepted) = when (message) {
            is ClientMessage.Answer -> message.callId to commands.answer(message.callId)
            is ClientMessage.Reject -> message.callId to commands.reject(message.callId)
            is ClientMessage.Hangup -> message.callId to commands.hangup(message.callId)
            is ClientMessage.Hello, null -> return send(ServerMessage.Error("bad_message"))
        }
        if (!accepted) send(ServerMessage.Error("unknown_call", callId))
    }

    private suspend fun reject(code: String) {
        send(ServerMessage.Error(code))
        ws.close(CloseReason(CloseReason.Codes.VIOLATED_POLICY, code))
    }

    private suspend fun send(message: ServerMessage) = ws.send(Frame.Text(message.encode()))

    private fun tokenMatches(candidate: String): Boolean =
        MessageDigest.isEqual(candidate.toByteArray(), token.toByteArray())
}

private fun CallEvent.toMessage(): ServerMessage? = when (this) {
    is CallEvent.Ringing -> ServerMessage.Ring(call.id, call.number)
    is CallEvent.Ended -> ServerMessage.Ended(call.id, reason = if (missed) "missed" else null)
    is CallEvent.Dialing, is CallEvent.Answered -> null
}
