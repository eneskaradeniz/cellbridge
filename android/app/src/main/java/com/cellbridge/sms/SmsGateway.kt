package com.cellbridge.sms

import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import kotlinx.coroutines.flow.SharedFlow

/** The SMS side of the host as the control server sees it. */
interface SmsGateway {
    val incoming: SharedFlow<IncomingSms>

    /** True while this app may read and send texts (the SMS permissions). */
    fun isAvailable(): Boolean

    /** Received texts the client has not acknowledged yet, oldest first. */
    suspend fun unacknowledged(): List<IncomingSms>

    /** Acknowledges [id] and every earlier text. */
    suspend fun acknowledge(id: Long)

    /** [clientId], when given, makes the send idempotent and ties the operator's delivery report to it. */
    suspend fun send(to: String, body: String, clientId: String? = null): SendResult

    /** Delivery reports as they arrive: the client id and whether the text was delivered. */
    val statuses: SharedFlow<SmsStatus>

    /** Client ids whose delivery report said delivered. */
    suspend fun delivered(): List<String>
}

data class SmsStatus(val clientId: String, val delivered: Boolean)

/** Files a sent text in the system SMS database; only the default SMS app may, so this goes through the root daemon. */
fun interface SentSmsWriter {
    suspend fun write(to: String, body: String, timestamp: Long): Boolean
}

/** The system SMS database (read-only for this app) plus the acknowledgement cursor. */
interface SmsStore {
    /** Sets the acknowledgement cursor to the newest text already in the inbox, the first time only: older history is never replayed. */
    suspend fun prime()

    /** Files a text the client sent in the sent box, so the phone's Messages app shows it. */
    suspend fun saveSent(to: String, body: String, timestamp: Long)

    suspend fun unacknowledged(): List<IncomingSms>

    fun acknowledge(id: Long)
}

/** Hands a text to the radio; true only if every part was sent. [tag] comes back with the delivery report. */
interface SmsSender {
    suspend fun send(to: String, body: String, tag: String? = null): Boolean
}

/** What reading and sending texts needs; the stock Messages app holds the default SMS role. */
val SMS_PERMISSIONS = arrayOf(
    android.Manifest.permission.READ_SMS,
    android.Manifest.permission.SEND_SMS,
    android.Manifest.permission.RECEIVE_SMS,
)

fun interface SmsRole {
    fun held(): Boolean
}
