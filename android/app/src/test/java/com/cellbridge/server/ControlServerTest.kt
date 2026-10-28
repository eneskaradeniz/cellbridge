package com.cellbridge.server

import com.cellbridge.audio.CallAudioBridge
import com.cellbridge.audio.FakeAudio
import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import com.cellbridge.sms.FakeSmsGateway
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.domain.model.EndReason
import com.cellbridge.protocol.ClientMessage
import com.cellbridge.protocol.PROTOCOL_VERSION
import com.cellbridge.protocol.ProtocolJson
import com.cellbridge.telecom.CallCommands
import com.cellbridge.telecom.CallFeed
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.server.testing.testApplication
import io.ktor.websocket.Frame
import io.ktor.websocket.readText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout
import java.util.concurrent.TimeUnit
import kotlin.time.Duration

class ControlServerTest {
    @get:Rule val timeout: Timeout = Timeout(30, TimeUnit.SECONDS)

    private class FakeFeed : CallFeed {
        val flow = MutableSharedFlow<CallEvent>(extraBufferCapacity = 8)
        var live: List<CallSnapshot> = emptyList()
        override val events: SharedFlow<CallEvent> = flow
        override fun liveCalls() = live
    }

    private class FakeCommands : CallCommands {
        val calls = mutableListOf<String>()
        override fun answer(callId: String) = callId == "c1".also { calls += "answer:$callId" }
        override fun reject(callId: String) = callId == "c1".also { calls += "reject:$callId" }
        override fun hangup(callId: String) = callId == "c1".also { calls += "hangup:$callId" }
    }

    private val feed = FakeFeed()
    private val commands = FakeCommands()
    private val audio = FakeAudio()
    private val sms = FakeSmsGateway()
    private val bridge = CallAudioBridge(feed, audio).also { it.start(CoroutineScope(Dispatchers.Unconfined + Job())) }
    private val incomingRinging = CallSnapshot("c1", "+90555", CallDirection.INCOMING, CallStatus.RINGING)

    private fun withServer(block: suspend (connect: suspend (suspend DefaultClientWebSocketSession.() -> Unit) -> Unit) -> Unit) =
        testApplication {
            application {
                controlModule(
                    feed, commands, bridge, sms, token = "SECRET",
                    capabilities = { listOf("calls") + if (audio.isAvailable()) listOf("audio") else emptyList() },
                    authFailureDelay = Duration.ZERO,
                )
            }
            val client = createClient { install(WebSockets) }
            block { session -> client.webSocket("/") { session() } }
        }

    private suspend fun DefaultClientWebSocketSession.say(text: String) = send(Frame.Text(text))

    private suspend fun DefaultClientWebSocketSession.hear(): JsonObject =
        Json.parseToJsonElement((incoming.receive() as Frame.Text).readText()).jsonObject

    private suspend fun DefaultClientWebSocketSession.login() {
        say("""{"type":"hello","version":$PROTOCOL_VERSION,"token":"SECRET"}""")
        assertEquals("hello_ack", hear()["type"]?.jsonPrimitive?.content)
    }

    /** The server handles client messages asynchronously; wait until [check] holds (real time, not test time). */
    private suspend fun eventually(check: () -> Boolean) = withContext(Dispatchers.Default) {
        withTimeout(5_000) { while (!check()) delay(10) }
    }

    private fun JsonObject.str(key: String) = get(key)?.jsonPrimitive?.content

    @Test
    fun `valid hello is acked with version and capabilities`() = withServer { connect ->
        connect {
            say("""{"type":"hello","version":1,"token":"SECRET"}""")
            assertEquals("""{"type":"hello_ack","version":1,"capabilities":["calls","audio"]}""", hear().toString())
        }
    }

    @Test
    fun `wrong token is refused`() = withServer { connect ->
        connect {
            say("""{"type":"hello","version":1,"token":"WRONG"}""")
            assertEquals("unauthorized", hear().str("code"))
        }
    }

    @Test
    fun `wrong version is refused`() = withServer { connect ->
        connect {
            say("""{"type":"hello","version":99,"token":"SECRET"}""")
            assertEquals("unsupported_version", hear().str("code"))
        }
    }

    @Test
    fun `anything before hello is refused`() = withServer { connect ->
        connect {
            say("""{"type":"answer","callId":"c1"}""")
            assertEquals("expected_hello", hear().str("code"))
        }
        assertEquals(emptyList<String>(), commands.calls)
    }

    @Test
    fun `ringing event is forwarded as ring`() = withServer { connect ->
        connect {
            login()
            feed.flow.emit(CallEvent.Ringing(incomingRinging))
            assertEquals("""{"type":"ring","callId":"c1","number":"+90555"}""", hear().toString())
        }
    }

    @Test
    fun `missed call is forwarded as ended with reason`() = withServer { connect ->
        connect {
            login()
            feed.flow.emit(CallEvent.Ended(incomingRinging.copy(status = CallStatus.DISCONNECTED), reason = EndReason.MISSED))
            assertEquals("""{"type":"ended","callId":"c1","reason":"missed"}""", hear().toString())
        }
    }

    @Test
    fun `rejected call is forwarded as ended with reason rejected`() = withServer { connect ->
        connect {
            login()
            feed.flow.emit(CallEvent.Ended(incomingRinging.copy(status = CallStatus.DISCONNECTED), reason = EndReason.REJECTED))
            assertEquals("""{"type":"ended","callId":"c1","reason":"rejected"}""", hear().toString())
        }
    }

    @Test
    fun `answered call ends without a reason`() = withServer { connect ->
        connect {
            login()
            feed.flow.emit(CallEvent.Ended(incomingRinging.copy(status = CallStatus.DISCONNECTED), reason = null))
            assertNull(hear().str("reason"))
        }
    }

    @Test
    fun `a reconnecting client is told about calls that are still ringing`() = withServer { connect ->
        feed.live = listOf(incomingRinging)
        connect {
            login()
            assertEquals("""{"type":"ring","callId":"c1","number":"+90555"}""", hear().toString())
        }
    }

    @Test
    fun `commands are routed and unknown calls are reported`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"answer","callId":"c1"}""")
            say("""{"type":"reject","callId":"c1"}""")
            say("""{"type":"hangup","callId":"nope"}""")
            val error = hear()
            assertEquals("unknown_call", error.str("code"))
            assertEquals("nope", error.str("message"))
        }
        assertEquals(listOf("answer:c1", "reject:c1", "hangup:nope"), commands.calls)
    }

    @Test
    fun `malformed message gets an error and the session stays open`() = withServer { connect ->
        connect {
            login()
            say("this is not json")
            assertEquals("bad_message", hear().str("code"))
            feed.flow.emit(CallEvent.Ringing(incomingRinging))
            assertEquals("ring", hear().str("type"))
        }
    }

    @Test
    fun `hello_ack advertises audio only while the daemon is available`() = withServer { connect ->
        connect {
            say("""{"type":"hello","version":$PROTOCOL_VERSION,"token":"SECRET"}""")
            assertEquals("""["calls","audio"]""", hear()["capabilities"].toString())
        }
        audio.available = false
        connect {
            say("""{"type":"hello","version":$PROTOCOL_VERSION,"token":"SECRET"}""")
            assertEquals("""["calls"]""", hear()["capabilities"].toString())
        }
    }

    @Test
    fun `answer with a udp port starts audio towards the client once the call is active`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"answer","callId":"c1","udpPort":40123}""")
            eventually { "answer:c1" in commands.calls } // the platform's Answered event follows answer()
            feed.flow.emit(CallEvent.Answered(incomingRinging.copy(status = CallStatus.ACTIVE)))
            assertEquals(listOf(40123), audio.started.map { it.port })
            feed.flow.emit(CallEvent.Ended(incomingRinging.copy(status = CallStatus.DISCONNECTED), reason = null))
            assertEquals(1, audio.stops)
        }
    }

    @Test
    fun `answer without a udp port keeps the call control-only`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"answer","callId":"c1"}""")
            eventually { "answer:c1" in commands.calls }
            feed.flow.emit(CallEvent.Answered(incomingRinging.copy(status = CallStatus.ACTIVE)))
            assertEquals(emptyList<Int>(), audio.started.map { it.port })
        }
    }

    @Test
    fun `answer for an unknown call forgets the announced peer`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"answer","callId":"nope","udpPort":40123}""")
            assertEquals("unknown_call", hear().str("code"))
        }
    }

    @Test
    fun `a received text is forwarded to the client`() = withServer { connect ->
        connect {
            login()
            sms.flow.emit(IncomingSms(7, "+90555", "selam", 1_700_000_000_000))
            assertEquals("""{"type":"sms","id":"7","from":"+90555","body":"selam","ts":1700000000000}""", hear().toString())
        }
    }

    @Test
    fun `unacknowledged texts are re-sent after hello_ack`() = withServer { connect ->
        sms.pending = listOf(IncomingSms(5, "+90555", "bir", 1L), IncomingSms(6, "+90556", "iki", 2L))
        connect {
            login()
            assertEquals("5", hear().str("id"))
            assertEquals("6", hear().str("id"))
        }
    }

    @Test
    fun `without the sms role nothing is replayed`() = withServer { connect ->
        sms.available = false
        sms.pending = listOf(IncomingSms(5, "+90555", "bir", 1L))
        connect {
            login()
            say("""{"type":"sms_ack","id":"zzz"}""") // forces a round trip: the next frame must be the error
            assertEquals("bad_message", hear().str("code"))
        }
    }

    @Test
    fun `sms_ack acknowledges and a malformed id is a bad_message`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"sms_ack","id":"7"}""")
            say("""{"type":"sms_ack","id":"seven"}""")
            assertEquals("bad_message", hear().str("code"))
            assertEquals(listOf(7L), sms.acknowledged)
        }
    }

    @Test
    fun `sms_send is answered with a result carrying the client id`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"sms_send","clientId":"k1","to":"+90555","body":"selam"}""")
            assertEquals("""{"type":"sms_result","clientId":"k1","ok":true}""", hear().toString())
            assertEquals(listOf("+90555" to "selam"), sms.sent)

            sms.sendResult = SendResult.Failed("failed")
            say("""{"type":"sms_send","clientId":"k2","to":"+90555","body":"yine"}""")
            assertEquals("""{"type":"sms_result","clientId":"k2","ok":false,"error":"failed"}""", hear().toString())
        }
    }
}
