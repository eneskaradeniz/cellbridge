package com.cellbridge.history

/** One row of the phone's call log. [kind] is `incoming` (answered), `outgoing`, `missed` or `rejected` (docs/protocol.md). */
data class CallLogEntry(val id: Long, val number: String, val name: String?, val kind: String, val timestamp: Long, val durationSeconds: Int)

/** One text from the phone's SMS database. Incoming items carry the same id the live `sms` message does. */
data class TextHistoryItem(val id: String, val peer: String, val body: String, val timestamp: Long, val outgoing: Boolean)

/** What happened on the phone while the client was away, read from the system databases. */
interface HistorySource {
    /** True while the app may read the call log. */
    fun callsAvailable(): Boolean

    /** Entries with an id greater than [afterId] and a time not before [sinceMs], the newest [limit] of them, oldest first. */
    suspend fun calls(afterId: Long, sinceMs: Long, limit: Int): List<CallLogEntry>

    /** Texts not older than [sinceMs], the newest [limit] of them, oldest first. */
    suspend fun texts(sinceMs: Long, limit: Int): List<TextHistoryItem>
}

object NoHistory : HistorySource {
    override fun callsAvailable() = false
    override suspend fun calls(afterId: Long, sinceMs: Long, limit: Int) = emptyList<CallLogEntry>()
    override suspend fun texts(sinceMs: Long, limit: Int) = emptyList<TextHistoryItem>()
}

/** Maps the platform's call log type to the wire `kind`; null for rows the client has no use for (voicemail). */
fun callKind(type: Int): String? = when (type) {
    1, 7 -> "incoming" // INCOMING, ANSWERED_EXTERNALLY
    2 -> "outgoing"
    3 -> "missed"
    5, 6 -> "rejected" // REJECTED, BLOCKED
    else -> null
}
