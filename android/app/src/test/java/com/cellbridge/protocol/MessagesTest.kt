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

    @Test
    fun `sms and its result are encoded as in the protocol`() {
        assertEquals(
            """{"type":"sms","id":"7","from":"+90555","body":"selam","ts":1700000000000}""",
            ServerMessage.Sms("7", "+90555", "selam", 1_700_000_000_000).encode(),
        )
        assertEquals("""{"type":"sms_result","clientId":"k1","ok":true}""", ServerMessage.SmsResult("k1", true).encode())
        assertEquals(
            """{"type":"sms_result","clientId":"k1","ok":false,"error":"failed"}""",
            ServerMessage.SmsResult("k1", false, "failed").encode(),
        )
    }

    @Test
    fun `sms_ack and sms_send are decoded`() {
        assertEquals(ClientMessage.SmsAck("7"), decodeClientMessage("""{"type":"sms_ack","id":"7"}"""))
        assertEquals(
            ClientMessage.SmsSend("k1", "+90555", "selam"),
            decodeClientMessage("""{"type":"sms_send","clientId":"k1","to":"+90555","body":"selam"}"""),
        )
        assertNull(decodeClientMessage("""{"type":"sms_send","to":"+90555"}"""))
    }
}
