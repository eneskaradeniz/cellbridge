package com.cellbridge.server

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
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
    private val incomingRinging = CallSnapshot("c1", "+90555", CallDirection.INCOMING, CallStatus.RINGING)

    private fun withServer(block: suspend (connect: suspend (suspend DefaultClientWebSocketSession.() -> Unit) -> Unit) -> Unit) =
        testApplication {
            application {
                controlModule(feed, commands, token = "SECRET", capabilities = { listOf("calls") }, authFailureDelay = Duration.ZERO)
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

    private fun JsonObject.str(key: String) = get(key)?.jsonPrimitive?.content

    @Test
    fun `valid hello is acked with version and capabilities`() = withServer { connect ->
        connect {
            say("""{"type":"hello","version":1,"token":"SECRET"}""")
            assertEquals("""{"type":"hello_ack","version":1,"capabilities":["calls"]}""", hear().toString())
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
            feed.flow.emit(CallEvent.Ended(incomingRinging.copy(status = CallStatus.DISCONNECTED), missed = true))
            assertEquals("""{"type":"ended","callId":"c1","reason":"missed"}""", hear().toString())
        }
    }

    @Test
    fun `answered call ends without a reason`() = withServer { connect ->
        connect {
            login()
            feed.flow.emit(CallEvent.Ended(incomingRinging.copy(status = CallStatus.DISCONNECTED), missed = false))
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
}
