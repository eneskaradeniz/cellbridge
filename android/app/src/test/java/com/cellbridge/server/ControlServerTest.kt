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
import com.cellbridge.history.CallLogEntry
import com.cellbridge.history.HistorySource
import com.cellbridge.history.TextHistoryItem
import com.cellbridge.push.PushRegistry
import com.cellbridge.push.PushTarget
import com.cellbridge.protocol.ClientMessage
import com.cellbridge.protocol.PROTOCOL_VERSION
import com.cellbridge.protocol.ProtocolJson
import com.cellbridge.telecom.CallCommands
import com.cellbridge.telecom.CallDialer
import com.cellbridge.telecom.DialOutcome
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
        override fun silence(callId: String) = callId == "c1".also { calls += "silence:$callId" }
        override fun dtmf(callId: String, digit: Char) = callId == "c1".also { calls += "dtmf:$callId:$digit" }
    }

    private class FakeDialer : CallDialer {
        val numbers = mutableListOf<String>()
        var outcome: DialOutcome = DialOutcome.Placed("o1")
        override suspend fun dial(number: String): DialOutcome = outcome.also { numbers += number }
    }

    private class FakeHistory : HistorySource {
        var asked = emptyList<Triple<Long, Long, Int>>()
        override fun callsAvailable() = true
        override suspend fun calls(afterId: Long, sinceMs: Long, limit: Int): List<CallLogEntry> {
            asked = asked + Triple(afterId, sinceMs, limit)
            return listOf(
                CallLogEntry(11, "+90555", "Ali", "missed", 1_000, 0),
                CallLogEntry(12, "+90556", null, "outgoing", 2_000, 31),
            )
        }
        override suspend fun texts(sinceMs: Long, limit: Int) = listOf(
            TextHistoryItem("1793", "+90555", "merhaba", 1_000, outgoing = false),
            TextHistoryItem("out-7", "+90555", "selam", 2_000, outgoing = true),
        )
    }

    private class FakePush(var available: Boolean = true) : PushRegistry {
        var registered: PushTarget? = null
        override fun available() = available
        override fun register(target: PushTarget) { registered = target }
    }

    private val push = FakePush()
    private val presence = ClientPresence()
    private val history = FakeHistory()
    private val dialer = FakeDialer()
    private val feed = FakeFeed()
    private val commands = FakeCommands()
    private val audio = FakeAudio()
    private val sms = FakeSmsGateway()
    private val bridge = CallAudioBridge(feed, audio).also { it.start(CoroutineScope(Dispatchers.Unconfined + Job())) }
    private val transfers = TransferController(presence, bridge)
    private val incomingRinging = CallSnapshot("c1", "+90555", CallDirection.INCOMING, CallStatus.RINGING)

    private fun withServer(
        status: com.cellbridge.status.PhoneStatusSource = com.cellbridge.status.NoPhoneStatus,
        block: suspend (connect: suspend (suspend DefaultClientWebSocketSession.() -> Unit) -> Unit) -> Unit,
    ) =
        testApplication {
            application {
                controlModule(
                    feed, commands, bridge, sms, dialer, token = "SECRET",
                    capabilities = { listOf("calls") + if (audio.isAvailable()) listOf("audio") else emptyList() },
                    authFailureDelay = Duration.ZERO,
                    history = history,
                    push = push,
                    presence = presence,
                    transfers = transfers,
                    phoneStatus = status,
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

    @Test
    fun `dial is answered with the id of the new call`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"dial","clientId":"d1","number":"+905551112233"}""")
            assertEquals("""{"type":"dial_result","clientId":"d1","ok":true,"callId":"o1"}""", hear().toString())
            assertEquals(listOf("+905551112233"), dialer.numbers)
        }
    }

    @Test
    fun `a refused dial reports why`() = withServer { connect ->
        dialer.outcome = DialOutcome.Failed("emergency")
        connect {
            login()
            say("""{"type":"dial","clientId":"d2","number":"112"}""")
            assertEquals("""{"type":"dial_result","clientId":"d2","ok":false,"error":"emergency"}""", hear().toString())
        }
    }

    @Test
    fun `audio follows an outgoing call once the far end answers`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"dial","clientId":"d1","number":"+905551112233","udpPort":40222}""")
            hear() // dial_result
            val outgoing = CallSnapshot("o1", "+905551112233", CallDirection.OUTGOING, CallStatus.ACTIVE)
            feed.flow.emit(CallEvent.Answered(outgoing))
            assertEquals("""{"type":"answered","callId":"o1"}""", hear().toString())
            assertEquals(listOf(40222), audio.started.map { it.port })
            feed.flow.emit(CallEvent.Ended(outgoing.copy(status = CallStatus.DISCONNECTED), reason = null))
            assertEquals(1, audio.stops)
        }
    }

    @Test
    fun `an answered call is announced to the client`() = withServer { connect ->
        connect {
            login()
            feed.flow.emit(CallEvent.Answered(incomingRinging.copy(status = CallStatus.ACTIVE)))
            assertEquals("""{"type":"answered","callId":"c1"}""", hear().toString())
        }
    }

    @Test
    fun `call log request is answered with the newer entries`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"call_log_request","after":"10","since":500}""")
            val reply = hear()
            assertEquals("call_log", reply.str("type"))
            assertEquals(
                """[{"id":"11","number":"+90555","name":"Ali","kind":"missed","ts":1000,"duration":0},""" +
                    """{"id":"12","number":"+90556","kind":"outgoing","ts":2000,"duration":31}]""",
                reply["entries"].toString(),
            )
            assertEquals(listOf(Triple(10L, 500L, 300)), history.asked)
        }
    }

    @Test
    fun `call log request without bounds asks for everything`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"call_log_request"}""")
            hear()
            assertEquals(listOf(Triple(0L, 0L, 300)), history.asked)
        }
    }

    @Test
    fun `sms history answers with incoming and outgoing texts`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"sms_history_request","since":1}""")
            val reply = hear()
            assertEquals("sms_history", reply.str("type"))
            assertEquals(
                """[{"id":"1793","peer":"+90555","body":"merhaba","ts":1000,"dir":"in"},""" +
                    """{"id":"out-7","peer":"+90555","body":"selam","ts":2000,"dir":"out"}]""",
                reply["items"].toString(),
            )
        }
    }

    private val goodKey = java.util.Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })

    @Test
    fun `a push token is stored`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"push_token","token":"${"ab".repeat(32)}","env":"sandbox","topic":"com.example.app.voip","key":"$goodKey"}""")
            eventually { push.registered != null }
            val target = push.registered!!
            assertEquals("ab".repeat(32), target.token)
            assertEquals(true, target.sandbox)
            assertEquals("com.example.app.voip", target.topic)
            assertEquals(32, target.key.size)
        }
    }

    @Test
    fun `a malformed push token is refused and not stored`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"push_token","token":"short","env":"sandbox","topic":"t","key":"$goodKey"}""")
            assertEquals("bad_message", hear().str("code"))
            say("""{"type":"push_token","token":"${"ab".repeat(32)}","env":"sandbox","topic":"t","key":"AAAA"}""")
            assertEquals("bad_message", hear().str("code"))
            assertNull(push.registered)
        }
    }

    @Test
    fun `a push token is refused while the host has no APNs key`() = withServer { connect ->
        push.available = false
        connect {
            login()
            say("""{"type":"push_token","token":"${"ab".repeat(32)}","env":"production","topic":"t","key":"$goodKey"}""")
            assertEquals("bad_message", hear().str("code"))
        }
    }

    @Test
    fun `the presence count follows the connection`() = withServer { connect ->
        connect {
            login()
            eventually { presence.connected }
        }
        eventually { !presence.connected }
    }

    @Test
    fun `a ring ack silences the phone and gets no reply`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"ring_ack","callId":"c1"}""")
            eventually { commands.calls == listOf("silence:c1") }
        }
    }

    private val activeCall = CallSnapshot("c1", "+90555", CallDirection.INCOMING, CallStatus.ACTIVE)

    @Test
    fun `transfer to the phone stops the relay and answers`() = withServer { connect ->
        bridge.expect("c1", java.net.InetSocketAddress("127.0.0.1", 40000))
        feed.live = listOf(activeCall)
        feed.flow.emit(CallEvent.Answered(activeCall))
        eventually { audio.started.isNotEmpty() }
        connect {
            login()
            say("""{"type":"transfer_to_host","callId":"c1"}""")
            val reply = hear()
            assertEquals("transfer_result", reply.str("type"))
            assertEquals("true", reply.str("ok"))
            assertEquals(1, audio.stops)
            say("""{"type":"transfer_to_host","callId":"c1"}""")
            assertEquals("false", hear().str("ok")) // not relayed any more
        }
    }

    @Test
    fun `transfer accept starts the relay for an active call`() = withServer { connect ->
        feed.live = listOf(activeCall)
        connect {
            login()
            say("""{"type":"transfer_accept","callId":"c1","udpPort":40001}""")
            eventually { audio.started.size == 1 }
            assertEquals(40001, audio.started.single().port)
        }
    }

    @Test
    fun `transfer accept for an unknown call is an error`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"transfer_accept","callId":"nope","udpPort":40001}""")
            assertEquals("unknown_call", hear().str("code"))
        }
    }

    @Test
    fun `an offer from the phone reaches the client with the number and when the call connected`() = withServer { connect ->
        feed.live = listOf(activeCall.copy(connectedAtMs = 1_700_000_000_000))
        connect {
            login()
            eventually { presence.connected }
            assertEquals(true, transfers.toIphone("c1"))
            val offer = hear()
            assertEquals("transfer_offer", offer.str("type"))
            assertEquals("c1", offer.str("callId"))
            assertEquals("+90555", offer.str("number"))
            assertEquals("1700000000000", offer.str("connectedAt"))
        }
    }

    @Test
    fun `an offer with no client connected is refused`() {
        assertEquals(false, TransferController(ClientPresence(), bridge).toIphone("c1"))
    }

    @Test
    fun `taking the call back stops the relay and tells the client`() = withServer { connect ->
        bridge.expect("c1", java.net.InetSocketAddress("127.0.0.1", 40000))
        feed.live = listOf(activeCall)
        feed.flow.emit(CallEvent.Answered(activeCall))
        eventually { audio.started.isNotEmpty() }
        connect {
            login()
            eventually { presence.connected }
            assertEquals(true, transfers.toPhone("c1"))
            val reply = hear()
            assertEquals("transfer_result", reply.str("type"))
            assertEquals("true", reply.str("ok"))
            assertEquals(1, audio.stops)
            assertEquals(false, transfers.toPhone("c1")) // already on the phone
        }
    }

    @Test
    fun `a keypad tone reaches the call`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"dtmf","callId":"c1","digit":"5"}""")
            say("""{"type":"dtmf","callId":"c1","digit":"#"}""")
            eventually { commands.calls == listOf("dtmf:c1:5", "dtmf:c1:#") }
        }
    }

    @Test
    fun `a keypad tone for an unknown call or with a bad digit is an error`() = withServer { connect ->
        connect {
            login()
            say("""{"type":"dtmf","callId":"nope","digit":"5"}""")
            assertEquals("unknown_call", hear().str("code"))
            say("""{"type":"dtmf","callId":"c1","digit":"55"}""")
            assertEquals("bad_message", hear().str("code"))
            say("""{"type":"dtmf","callId":"c1","digit":"x"}""")
            assertEquals("bad_message", hear().str("code"))
            assertEquals(listOf("dtmf:nope:5"), commands.calls) // the bad digits never reached the call
        }
    }

    @Test
    fun `the phone's status follows hello_ack`() = withServer(
        status = com.cellbridge.status.PhoneStatusSource { com.cellbridge.status.PhoneStatus(78, true, 3, "Turkcell") },
    ) { connect ->
        connect {
            login()
            val status = hear()
            assertEquals("host_status", status.str("type"))
            assertEquals("78", status.str("battery"))
            assertEquals("true", status.str("charging"))
            assertEquals("3", status.str("signal"))
            assertEquals("Turkcell", status.str("operator"))
        }
    }
}
