package com.cellbridge.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

const val PROTOCOL_VERSION = 1

/** Wire format of the control channel; keep in sync with docs/protocol.md. */
val ProtocolJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = false
}

@Serializable
sealed interface ClientMessage {
    @Serializable @SerialName("hello")
    data class Hello(val version: Int, val token: String) : ClientMessage

    @Serializable @SerialName("answer")
    data class Answer(val callId: String, val udpPort: Int? = null) : ClientMessage

    @Serializable @SerialName("reject")
    data class Reject(val callId: String) : ClientMessage

    @Serializable @SerialName("hangup")
    data class Hangup(val callId: String) : ClientMessage

    @Serializable @SerialName("ring_ack")
    data class RingAck(val callId: String) : ClientMessage

    @Serializable @SerialName("dtmf")
    data class Dtmf(val callId: String, val digit: String) : ClientMessage

    @Serializable @SerialName("transfer_to_host")
    data class TransferToHost(val callId: String) : ClientMessage

    @Serializable @SerialName("transfer_accept")
    data class TransferAccept(val callId: String, val udpPort: Int? = null) : ClientMessage

    @Serializable @SerialName("transfer_request")
    data class TransferRequest(val callId: String) : ClientMessage

    @Serializable @SerialName("call_state_request")
    data object CallStateRequest : ClientMessage

    @Serializable @SerialName("dial")
    data class Dial(val clientId: String, val number: String, val udpPort: Int? = null) : ClientMessage

    @Serializable @SerialName("sms_ack")
    data class SmsAck(val id: String) : ClientMessage

    @Serializable @SerialName("sms_send")
    data class SmsSend(val clientId: String, val to: String, val body: String) : ClientMessage

    @Serializable @SerialName("call_log_request")
    data class CallLogRequest(val after: String? = null, val since: Long? = null) : ClientMessage

    @Serializable @SerialName("sms_history_request")
    data class SmsHistoryRequest(val since: Long? = null) : ClientMessage

    @Serializable @SerialName("push_token")
    data class PushToken(
        val token: String, val env: String, val topic: String, val key: String,
        @SerialName("alert_token") val alertToken: String? = null,
        @SerialName("alert_topic") val alertTopic: String? = null,
    ) : ClientMessage
}

@Serializable
sealed interface ServerMessage {
    @Serializable @SerialName("hello_ack")
    data class HelloAck(val version: Int, val capabilities: List<String>) : ServerMessage

    @Serializable @SerialName("call_list")
    data class CallList(val callIds: List<String>) : ServerMessage

    @Serializable @SerialName("capabilities")
    data class Capabilities(val capabilities: List<String>) : ServerMessage

    @Serializable @SerialName("tone")
    data class Tone(val action: String, val kind: String? = null, val id: Int? = null, val name: String? = null) : ServerMessage

    @Serializable @SerialName("ring")
    data class Ring(val callId: String, val number: String? = null, val name: String? = null) : ServerMessage

    @Serializable @SerialName("ended")
    data class Ended(val callId: String, val reason: String? = null) : ServerMessage

    @Serializable @SerialName("dial_result")
    data class DialResult(val clientId: String, val ok: Boolean, val callId: String? = null, val error: String? = null) : ServerMessage

    @Serializable @SerialName("answered")
    data class Answered(val callId: String) : ServerMessage

    @Serializable @SerialName("sms")
    data class Sms(val id: String, val from: String, val body: String, val ts: Long) : ServerMessage

    @Serializable @SerialName("sms_result")
    data class SmsResult(val clientId: String, val ok: Boolean, val error: String? = null) : ServerMessage

    @Serializable @SerialName("transfer_result")
    data class TransferResult(val callId: String, val ok: Boolean) : ServerMessage

    @Serializable @SerialName("call_state")
    data class CallState(val calls: List<CallStateItem>) : ServerMessage

    @Serializable @SerialName("transfer_offer")
    data class TransferOffer(val callId: String, val number: String? = null, val connectedAt: Long? = null) : ServerMessage

    @Serializable @SerialName("sms_status")
    data class SmsStatus(val clientId: String, val status: String) : ServerMessage

    @Serializable @SerialName("host_status")
    data class HostStatus(val battery: Int? = null, val charging: Boolean = false, val signal: Int? = null, val operator: String? = null) : ServerMessage

    @Serializable @SerialName("call_log")
    data class CallLog(val entries: List<CallLogItem>) : ServerMessage

    @Serializable @SerialName("sms_history")
    data class SmsHistory(val items: List<SmsHistoryItem>) : ServerMessage

    @Serializable @SerialName("error")
    data class Error(val code: String, val message: String? = null) : ServerMessage
}

@Serializable
data class CallStateItem(
    val callId: String,
    val number: String? = null,
    val direction: String,
    val status: String,
    val connectedAt: Long? = null,
    val onClient: Boolean,
)

@Serializable
data class CallLogItem(val id: String, val number: String, val name: String? = null, val kind: String, val ts: Long, val duration: Int)

@Serializable
data class SmsHistoryItem(val id: String, val peer: String, val body: String, val ts: Long, val dir: String)

fun ServerMessage.encode(): String = ProtocolJson.encodeToString(ServerMessage.serializer(), this)

/** Returns null for anything that is not a valid client message. */
fun decodeClientMessage(text: String): ClientMessage? =
    runCatching { ProtocolJson.decodeFromString(ClientMessage.serializer(), text) }.getOrNull()
