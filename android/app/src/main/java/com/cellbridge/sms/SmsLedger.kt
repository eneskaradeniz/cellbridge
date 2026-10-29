package com.cellbridge.sms

import android.content.Context
import com.cellbridge.domain.model.SendResult
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/** Where the ledger keeps itself between runs. */
interface LedgerStore {
    fun load(): String?
    fun save(text: String)
}

@Singleton
class PrefsLedgerStore @Inject constructor(@ApplicationContext context: Context) : LedgerStore {
    private val prefs = context.getSharedPreferences("sms_ledger", Context.MODE_PRIVATE)
    override fun load(): String? = prefs.getString("entries", null)
    override fun save(text: String) { prefs.edit().putString("entries", text).apply() }
}

@Serializable
private class Row(val id: String, val ok: Boolean, val error: String? = null, val delivered: Boolean = false)

/**
 * Remembers every text sent for a client, by the client's id: a repeated id gets the earlier answer instead of a second text,
 * so a client may safely send again what it never heard back about. Also holds the operator's delivery reports.
 */
@Singleton
class SmsLedger @Inject constructor(private val store: LedgerStore) {
    private class Entry(var result: SendResult, var delivered: Boolean)

    private val entries = LinkedHashMap<String, Entry>()
    private val inFlight = ConcurrentHashMap<String, CompletableDeferred<SendResult>>()

    init {
        runCatching { Json.decodeFromString(ListSerializer(Row.serializer()), store.load().orEmpty()) }.getOrDefault(emptyList()).forEach {
            entries[it.id] = Entry(if (it.ok) SendResult.Sent else SendResult.Failed(it.error ?: "failed"), it.delivered)
        }
    }

    /** Runs [send] unless [clientId] was sent before (or is being sent right now): then the earlier result is returned. */
    suspend fun sendOnce(clientId: String, send: suspend () -> SendResult): SendResult {
        synchronized(this) { entries[clientId]?.result }?.let { return it }
        val mine = CompletableDeferred<SendResult>()
        inFlight.putIfAbsent(clientId, mine)?.let { return it.await() } // a repeat while the first is still going out
        return try {
            send().also { remember(clientId, it) }.also(mine::complete)
        } catch (e: Throwable) {
            mine.completeExceptionally(e)
            throw e
        } finally {
            inFlight.remove(clientId)
        }
    }

    /** True if this changed what is known (a new delivery report). */
    @Synchronized
    fun markDelivered(clientId: String): Boolean {
        val entry = entries[clientId] ?: return false
        if (entry.delivered) return false
        entry.delivered = true
        persist()
        return true
    }

    @Synchronized
    fun delivered(): List<String> = entries.filterValues { it.delivered }.keys.toList()

    @Synchronized
    private fun remember(clientId: String, result: SendResult) {
        entries[clientId] = Entry(result, delivered = false)
        while (entries.size > LIMIT) entries.remove(entries.keys.first())
        persist()
    }

    private fun persist() {
        val rows = entries.map { (id, e) -> Row(id, e.result is SendResult.Sent, (e.result as? SendResult.Failed)?.error, e.delivered) }
        store.save(Json.encodeToString(ListSerializer(Row.serializer()), rows))
    }

    private companion object {
        const val LIMIT = 300
    }
}

/** What an SMS status report (the 3GPP status byte) says: < 32 delivered, 32-63 still being tried, >= 64 never will be. */
fun deliveryOutcome(status: Int): Boolean? = when {
    status < 32 -> true
    status >= 64 -> false
    else -> null
}
