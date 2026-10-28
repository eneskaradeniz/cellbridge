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
}

@Serializable
sealed interface ServerMessage {
    @Serializable @SerialName("hello_ack")
    data class HelloAck(val version: Int, val capabilities: List<String>) : ServerMessage

    @Serializable @SerialName("ring")
    data class Ring(val callId: String, val number: String? = null, val name: String? = null) : ServerMessage

    @Serializable @SerialName("ended")
    data class Ended(val callId: String, val reason: String? = null) : ServerMessage

    @Serializable @SerialName("error")
    data class Error(val code: String, val message: String? = null) : ServerMessage
}

fun ServerMessage.encode(): String = ProtocolJson.encodeToString(ServerMessage.serializer(), this)

/** Returns null for anything that is not a valid client message. */
fun decodeClientMessage(text: String): ClientMessage? =
    runCatching { ProtocolJson.decodeFromString(ClientMessage.serializer(), text) }.getOrNull()
