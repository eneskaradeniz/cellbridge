package com.cellbridge.sms

import android.util.Log
import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Receives texts from the SMS_DELIVER receiver, stores them first, then announces them. Storing before announcing
 * is what makes delivery lossless: whatever the client misses is still in the database.
 */
@Singleton
class SmsRepository @Inject constructor(
    private val store: SmsStore,
    private val sender: SmsSender,
    private val role: SmsRole,
    private val ledger: SmsLedger,
) : SmsGateway {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _incoming = MutableSharedFlow<IncomingSms>(extraBufferCapacity = 16)

    override val incoming: SharedFlow<IncomingSms> = _incoming.asSharedFlow()

    private val _statuses = MutableSharedFlow<SmsStatus>(extraBufferCapacity = 16)

    override val statuses: SharedFlow<SmsStatus> = _statuses.asSharedFlow()

    override fun isAvailable() = role.held()

    override suspend fun delivered() = ledger.delivered()

    /** The operator's report for a text sent with [clientId] came in. */
    fun onDelivery(clientId: String, delivered: Boolean) {
        if (delivered && !ledger.markDelivered(clientId)) return // already known
        _statuses.tryEmit(SmsStatus(clientId, delivered))
    }

    /** Returns the job so a broadcast receiver can keep its process alive until the text is stored. */
    fun onReceived(from: String, body: String, timestamp: Long): Job = scope.launch {
        runCatching { store.saveIncoming(from, body, timestamp) }
            .onFailure { Log.e(TAG, "could not store a received text", it) }
            .getOrNull()
            ?.let {
                Log.i(TAG, "Sms id=${it.id}") // never log the number or the text
                _incoming.emit(it)
            }
    }

    override suspend fun unacknowledged() = store.unacknowledged()

    override suspend fun acknowledge(id: Long) = store.acknowledge(id)

    override suspend fun send(to: String, body: String, clientId: String?): SendResult {
        if (clientId == null) return sendNow(to, body, null)
        return ledger.sendOnce(clientId) { sendNow(to, body, clientId) }
    }

    private suspend fun sendNow(to: String, body: String, clientId: String?): SendResult {
        if (!NUMBER.matches(to) || body.isBlank() || body.length > MAX_BODY) return SendResult.Failed("invalid")
        if (!sender.send(to, body, clientId)) return SendResult.Failed("failed")
        runCatching { store.saveSent(to, body, System.currentTimeMillis()) }
            .onFailure { Log.w(TAG, "sent text not stored", it) } // it did go out; do not report a failure
        return SendResult.Sent
    }

    private companion object {
        const val TAG = "CellBridge"
        const val MAX_BODY = 1_000
        val NUMBER = Regex("""\+?[0-9 ()\-]{3,20}""")
    }
}
