package com.cellbridge.sms

import android.content.Context
import android.provider.Telephony
import com.cellbridge.domain.model.IncomingSms
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Reads the texts the phone's stock Messages app (the default SMS app) stores. A text's id is its `date` column, the time the
 * stock app stored it, not the row id: SQLite reuses row ids after deletions, which would make a new text look like an old,
 * already acknowledged one. The cursor is the id of the last text the client acknowledged; it starts at the newest text present
 * when the bridge first runs, so history from before is never replayed to the iPhone. Two texts stored in the same millisecond
 * share an id, and acknowledging one hides the other: accepted, a SIM delivers texts far slower than that.
 */
@Singleton
class TelephonySmsStore @Inject constructor(
    @ApplicationContext context: Context,
    private val sentWriter: SentSmsWriter,
) : SmsStore {
    private val resolver = context.contentResolver
    private val prefs = context.getSharedPreferences("sms", Context.MODE_PRIVATE)

    override suspend fun prime() {
        if (prefs.contains(CURSOR)) return
        withContext(Dispatchers.IO) {
            val newest = runCatching {
                resolver.query(Telephony.Sms.Inbox.CONTENT_URI, arrayOf(Telephony.Sms.DATE), null, null, "${Telephony.Sms.DATE} DESC LIMIT 1")
                    ?.use { if (it.moveToFirst()) it.getLong(0) else 0L }
            }.getOrNull() ?: return@withContext // no read permission yet: try again next time
            synchronized(this@TelephonySmsStore) { if (!prefs.contains(CURSOR)) prefs.edit().putLong(CURSOR, newest).apply() }
        }
    }

    override suspend fun saveSent(to: String, body: String, timestamp: Long) {
        check(sentWriter.write(to, body, timestamp)) { "the daemon did not file the sent text" }
    }

    override suspend fun unacknowledged(): List<IncomingSms> = withContext(Dispatchers.IO) {
        val cursor = prefs.getLong(CURSOR, Long.MAX_VALUE) // no cursor yet: nothing has been stored, nothing to replay
        val columns = arrayOf(Telephony.Sms.DATE, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE_SENT)
        val result = mutableListOf<IncomingSms>()
        resolver.query(Telephony.Sms.Inbox.CONTENT_URI, columns, "${Telephony.Sms.DATE} > ?", arrayOf(cursor.toString()), "${Telephony.Sms.DATE} ASC")
            ?.use {
                while (it.moveToNext() && result.size < REPLAY_LIMIT) {
                    result += IncomingSms(it.getLong(0), it.getString(1).orEmpty(), it.getString(2).orEmpty(), it.getLong(3).takeIf { sent -> sent > 0 } ?: it.getLong(0)) // some texts carry no sent time
                }
            }
        result
    }

    @Synchronized
    override fun acknowledge(id: Long) {
        if (id > prefs.getLong(CURSOR, Long.MIN_VALUE)) prefs.edit().putLong(CURSOR, id).apply()
    }

    private companion object {
        const val CURSOR = "acked_stamp" // not "acked_id": cursors from the row-id scheme must not be reused
        const val REPLAY_LIMIT = 200
    }
}
