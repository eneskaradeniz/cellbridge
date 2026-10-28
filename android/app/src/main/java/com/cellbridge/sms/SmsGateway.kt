package com.cellbridge.sms

import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import kotlinx.coroutines.flow.SharedFlow

/** The SMS side of the host as the control server sees it. */
interface SmsGateway {
    val incoming: SharedFlow<IncomingSms>

    /** True while this app is the default SMS app, the only state in which texts can be read and written. */
    fun isAvailable(): Boolean

    /** Received texts the client has not acknowledged yet, oldest first. */
    suspend fun unacknowledged(): List<IncomingSms>

    /** Acknowledges [id] and every earlier text. */
    suspend fun acknowledge(id: Long)

    suspend fun send(to: String, body: String): SendResult
}

/** The system SMS database plus the acknowledgement cursor. */
interface SmsStore {
    /** Writes a received text to the inbox; null if the provider refused it. */
    suspend fun saveIncoming(from: String, body: String, timestamp: Long): IncomingSms?

    suspend fun saveSent(to: String, body: String, timestamp: Long)

    suspend fun unacknowledged(): List<IncomingSms>

    fun acknowledge(id: Long)
}

/** Hands a text to the radio; true only if every part was sent. */
interface SmsSender {
    suspend fun send(to: String, body: String): Boolean
}

fun interface SmsRole {
    fun held(): Boolean
}
