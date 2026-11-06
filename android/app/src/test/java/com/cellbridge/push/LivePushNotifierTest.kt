package com.cellbridge.push

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.server.ClientPresence
import com.cellbridge.sms.FakeSmsGateway
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec

class LivePushNotifierTest {
    private class FakeFeed : CallFeed {
        override val events: SharedFlow<CallEvent> = MutableSharedFlow(extraBufferCapacity = 8)
        var live = emptyList<CallSnapshot>()
        override fun liveCalls() = live
    }

    private class FakeStore(var target: PushTarget?) : PushStore {
        override fun load() = target
        override fun save(target: PushTarget) { this.target = target }
        override fun clear() { target = null }
    }

    private class Post(val path: String, val headers: Map<String, String>, val body: String)

    private class FakeTransport(var status: Int = 200) : ApnsTransport {
        val posts = mutableListOf<Post>()
        override suspend fun post(host: String, path: String, headers: Map<String, String>, body: ByteArray): Int {
            posts += Post(path, headers, body.decodeToString())
            return status
        }
    }

    private val key = ByteArray(32) { it.toByte() }
    private val feed = FakeFeed()
    private val store = FakeStore(PushTarget("a".repeat(64), true, "com.example.app.voip", key, alertToken = "c".repeat(64), alertTopic = "com.example.app"))
    private val transport = FakeTransport()
    private val bridged = MutableStateFlow(emptySet<String>())
    private val ecKey = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair().private
    private val push = PushNotifier(feed, store, { ApnsCredentials("KID", "TEAM", ecKey) }, transport, ClientPresence(), FakeSmsGateway())
        .also { it.nowMs = { 1_700_000_000_000 } }
    private val live = LivePushNotifier(feed, store, push).also { it.start(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined), bridged) }
    private val startToken = "s".repeat(64)
    private val updateToken = "u".repeat(64)

    private fun call(status: CallStatus = CallStatus.ACTIVE, id: String = "c1") =
        CallSnapshot(id, "+905551112233", CallDirection.OUTGOING, status, connectedAtMs = 1_699_999_000_000)

    private fun events() = transport.posts.map { Regex(""""event":"(\w+)"""").find(it.body)!!.groupValues[1] }

    @Test fun `a call that becomes active on the phone starts an activity with the start token`() = runTest {
        live.startToken(startToken)
        feed.live = listOf(call())
        live.reconcile()
        val post = transport.posts.single()
        assertEquals("/3/device/$startToken", post.path)
        assertEquals("liveactivity", post.headers["apns-push-type"])
        assertEquals("com.example.app.push-type.liveactivity", post.headers["apns-topic"])
        assertTrue(post.body.contains(""""attributes-type":"CallActivityAttributes""""))
        assertTrue(post.body.contains(""""attributes":{"callId":"c1"}"""))
        assertTrue(post.body.contains(""""status":"active"""") && post.body.contains(""""connectedAtMs":1699999000000"""))
        assertTrue(post.body.contains(""""stale-date":1700014400"""))
        assertTrue(post.body.contains(""""alert":{"title":"CellBridge","body":"On the phone","loc-key":"On the phone"}"""))
        assertTrue("the number must not travel in clear", !post.body.contains("905551112233"))
        val sealed = Regex(""""sealed":"([^"]+)"""").find(post.body)!!.groupValues[1]
        assertEquals("""{"number":"+905551112233"}""", PushCrypto.open(key, sealed)?.decodeToString())
    }

    @Test fun `a ringing or relayed call gets no activity`() = runTest {
        live.startToken(startToken)
        feed.live = listOf(call(CallStatus.RINGING), call(CallStatus.ACTIVE, "c2"))
        bridged.value = setOf("c2")
        live.reconcile()
        assertTrue(transport.posts.isEmpty())
    }

    @Test fun `without a start token nothing is sent`() = runTest {
        feed.live = listOf(call())
        live.reconcile()
        assertTrue(transport.posts.isEmpty())
    }

    @Test fun `a status change waits for the update token, then updates once`() = runTest {
        live.startToken(startToken)
        feed.live = listOf(call())
        live.reconcile()
        feed.live = listOf(call(CallStatus.HOLDING))
        live.reconcile()
        assertEquals(listOf("start"), events()) // no update token yet
        live.updateToken("c1", updateToken)
        assertEquals(listOf("start", "update"), events())
        assertEquals("/3/device/$updateToken", transport.posts.last().path)
        assertTrue(transport.posts.last().body.contains(""""status":"holding""""))
        assertTrue("only the start carries an alert", !transport.posts.last().body.contains("alert"))
        live.reconcile()
        assertEquals(2, transport.posts.size) // nothing new to say
    }

    @Test fun `hanging up ends the activity, and an end that had no token yet goes out when it arrives`() = runTest {
        live.startToken(startToken)
        feed.live = listOf(call())
        live.reconcile()
        feed.live = emptyList()
        live.reconcile()
        assertEquals(listOf("start"), events())
        live.updateToken("c1", updateToken)
        assertEquals(listOf("start", "end"), events())
        assertTrue(transport.posts.last().body.contains(""""dismissal-date":1700000000"""))
        live.reconcile()
        assertEquals(2, transport.posts.size) // forgotten after the end
    }

    @Test fun `taking the call over ends the activity`() = runTest {
        live.startToken(startToken)
        feed.live = listOf(call())
        live.reconcile()
        live.updateToken("c1", updateToken)
        bridged.value = setOf("c1")
        live.reconcile()
        assertEquals(listOf("start", "end"), events())
    }

    @Test fun `a failed start is tried again on the next change`() = runTest {
        live.startToken(startToken)
        feed.live = listOf(call())
        transport.status = 503
        live.reconcile()
        transport.status = 200
        live.reconcile()
        assertEquals(listOf("start", "start"), events())
        live.reconcile()
        assertEquals(2, transport.posts.size)
    }

    @Test fun `a refused start token is forgotten and the live token survives a new push token`() = runTest {
        live.startToken(startToken)
        assertEquals(startToken, store.target!!.liveStartToken)
        push.register(PushTarget("b".repeat(64), true, "t", key, alertToken = "c".repeat(64), alertTopic = "com.example.app"))
        assertEquals(startToken, store.target!!.liveStartToken)
        transport.status = 400
        feed.live = listOf(call())
        live.reconcile()
        assertNull(store.target!!.liveStartToken)
    }
}
