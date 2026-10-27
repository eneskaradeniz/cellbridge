package com.cellbridge.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MessagesTest {
    @Test
    fun `ring omits absent fields and carries the type`() {
        assertEquals("""{"type":"ring","callId":"c1","number":"+90555"}""", ServerMessage.Ring("c1", "+90555").encode())
        assertEquals("""{"type":"ring","callId":"c1"}""", ServerMessage.Ring("c1").encode())
    }

    @Test
    fun `hello_ack lists capabilities`() {
        assertEquals(
            """{"type":"hello_ack","version":1,"capabilities":["calls"]}""",
            ServerMessage.HelloAck(1, listOf("calls")).encode(),
        )
    }

    @Test
    fun `client messages decode by type`() {
        assertEquals(ClientMessage.Hello(1, "ABC"), decodeClientMessage("""{"type":"hello","version":1,"token":"ABC"}"""))
        assertEquals(ClientMessage.Answer("c1"), decodeClientMessage("""{"type":"answer","callId":"c1"}"""))
        assertEquals(ClientMessage.Reject("c1"), decodeClientMessage("""{"type":"reject","callId":"c1"}"""))
        assertEquals(ClientMessage.Hangup("c1"), decodeClientMessage("""{"type":"hangup","callId":"c1"}"""))
    }

    @Test
    fun `unknown extra fields are ignored`() {
        assertEquals(ClientMessage.Answer("c1"), decodeClientMessage("""{"type":"answer","callId":"c1","future":true}"""))
    }

    @Test
    fun `garbage and unknown types decode to null`() {
        assertNull(decodeClientMessage("not json"))
        assertNull(decodeClientMessage("""{"type":"launch_missiles"}"""))
        assertNull(decodeClientMessage("""{"type":"answer"}"""))
    }
}
