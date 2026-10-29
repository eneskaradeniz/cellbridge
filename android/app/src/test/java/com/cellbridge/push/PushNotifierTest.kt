package com.cellbridge.push

import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallEvent
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import com.cellbridge.server.ClientPresence
import com.cellbridge.telecom.CallFeed
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec

@OptIn(ExperimentalCoroutinesApi::class)
class PushNotifierTest {
    private class FakeFeed : CallFeed {
        val flow = MutableSharedFlow<CallEvent>(extraBufferCapacity = 8)
        var live = emptyList<CallSnapshot>()
        override val events: SharedFlow<CallEvent> = flow
        override fun liveCalls() = live
    }

    private class FakeStore(var target: PushTarget? = null) : PushStore {
        override fun load() = target
        override fun save(target: PushTarget) { this.target = target }
        override fun clear() { target = null }
    }

    private class Post(val host: String, val path: String, val headers: Map<String, String>, val body: ByteArray)

    private class FakeTransport(var status: Int = 200) : ApnsTransport {
        val posts = mutableListOf<Post>()
        override suspend fun post(host: String, path: String, headers: Map<String, String>, body: ByteArray): Int {
            posts += Post(host, path, headers, body)
            return status
        }
    }

    private val key = ByteArray(32) { it.toByte() }
    private val feed = FakeFeed()
    private val store = FakeStore(PushTarget("a".repeat(64), sandbox = true, topic = "com.example.app.voip", key = key))
    private val transport = FakeTransport()
    private val presence = ClientPresence()
    private val ringing = CallSnapshot("c1", "+905551112233", CallDirection.INCOMING, CallStatus.RINGING)
    private val ecKey = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair().private
    private var credentials: ApnsCredentials? = ApnsCredentials("KID", "TEAM", ecKey)

    private fun notifier() = PushNotifier(feed, store, { credentials }, transport, presence).also { it.nowMs = { 1_700_000_000_000 } }

    @Test fun `with no client connected the push goes out at once`() = runTest {
        notifier().onRinging("c1", "+905551112233")
        val post = transport.posts.single()
        assertEquals("api.sandbox.push.apple.com", post.host)
        assertEquals("/3/device/${"a".repeat(64)}", post.path)
        assertEquals("voip", post.headers["apns-push-type"])
        assertEquals("com.example.app.voip", post.headers["apns-topic"])
        assertEquals("10", post.headers["apns-priority"])
        assertEquals("1700000020", post.headers["apns-expiration"])
        assertTrue(post.headers["authorization"]!!.startsWith("bearer "))
    }

    @Test fun `the body carries the call sealed under the shared key`() = runTest {
        notifier().onRinging("c1", "+905551112233")
        val body = transport.posts.single().body.decodeToString()
        val sealed = Regex(""""cb":"([^"]+)"""").find(body)!!.groupValues[1]
        assertEquals("""{"callId":"c1","number":"+905551112233"}""", PushCrypto.open(key, sealed)?.decodeToString())
        assertTrue("the number must not travel in clear", !body.contains("905551112233"))
    }

    @Test fun `production tokens go to the production host`() = runTest {
        store.target = PushTarget("b".repeat(64), sandbox = false, topic = "t", key = key)
        notifier().onRinging("c1", null)
        assertEquals("api.push.apple.com", transport.posts.single().host)
    }

    @Test fun `with a client connected it waits and pushes only if the call still rings`() = runTest {
        presence.joined()
        feed.live = listOf(ringing)
        val job = launchNotifier()
        advanceTimeBy(2_900)
        assertTrue(transport.posts.isEmpty())
        advanceTimeBy(200)
        job.join()
        assertEquals(1, transport.posts.size)
    }

    @Test fun `a call that ended while waiting sends nothing`() = runTest {
        presence.joined()
        feed.live = listOf(ringing)
        val job = launchNotifier()
        advanceTimeBy(1_000)
        feed.live = emptyList()
        advanceTimeBy(3_000)
        job.join()
        assertTrue(transport.posts.isEmpty())
    }

    @Test fun `nothing is sent without a token or without a key`() = runTest {
        store.target = null
        notifier().onRinging("c1", null)
        store.target = PushTarget("a".repeat(64), true, "t", key)
        credentials = null
        notifier().onRinging("c1", null)
        assertTrue(transport.posts.isEmpty())
    }

    @Test fun `a gone token is forgotten`() = runTest {
        transport.status = 410
        notifier().onRinging("c1", null)
        assertNull(store.target)
    }

    @Test fun `the provider token is reused within its lifetime`() = runTest {
        val n = notifier()
        n.onRinging("c1", null)
        n.onRinging("c2", null)
        assertEquals(transport.posts[0].headers["authorization"], transport.posts[1].headers["authorization"])
    }

    private fun TestScope.launchNotifier() = launch { notifier().onRinging("c1", "+905551112233") }
}
