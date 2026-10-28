package com.cellbridge.sms

import android.content.ContentValues
import android.content.Context
import android.provider.Telephony
import com.cellbridge.domain.model.IncomingSms
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Only the default SMS app may write the system SMS database, so this works while the role is held.
 *
 * A text's id is the strictly increasing arrival stamp we write into its `date` column, not the row id: SQLite
 * reuses row ids after deletions, which would make a new text look like an old, already acknowledged one.
 * The cursor is the stamp of the last text the client acknowledged; it starts just below the first text we store,
 * so history from before the bridge existed is never replayed to the iPhone.
 */
@Singleton
class TelephonySmsStore @Inject constructor(@ApplicationContext context: Context) : SmsStore {
    private val resolver = context.contentResolver
    private val prefs = context.getSharedPreferences("sms", Context.MODE_PRIVATE)

    override suspend fun saveIncoming(from: String, body: String, timestamp: Long): IncomingSms? = withContext(Dispatchers.IO) {
        val stamp = nextStamp()
        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, from)
            put(Telephony.Sms.BODY, body)
            put(Telephony.Sms.DATE, stamp)
            put(Telephony.Sms.DATE_SENT, timestamp)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.SEEN, 0)
        }
        resolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values) ?: return@withContext null
        initCursor(below = stamp)
        IncomingSms(stamp, from, body, timestamp)
    }

    override suspend fun saveSent(to: String, body: String, timestamp: Long) {
        withContext(Dispatchers.IO) {
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, to)
                put(Telephony.Sms.BODY, body)
                put(Telephony.Sms.DATE, timestamp)
                put(Telephony.Sms.READ, 1)
            }
            resolver.insert(Telephony.Sms.Sent.CONTENT_URI, values)
        }
    }

    override suspend fun unacknowledged(): List<IncomingSms> = withContext(Dispatchers.IO) {
        val cursor = prefs.getLong(CURSOR, Long.MAX_VALUE) // no cursor yet: nothing has been stored, nothing to replay
        val columns = arrayOf(Telephony.Sms.DATE, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE_SENT)
        val result = mutableListOf<IncomingSms>()
        resolver.query(Telephony.Sms.Inbox.CONTENT_URI, columns, "${Telephony.Sms.DATE} > ?", arrayOf(cursor.toString()), "${Telephony.Sms.DATE} ASC")
            ?.use {
                while (it.moveToNext() && result.size < REPLAY_LIMIT) {
                    result += IncomingSms(it.getLong(0), it.getString(1).orEmpty(), it.getString(2).orEmpty(), it.getLong(3))
                }
            }
        result
    }

    @Synchronized
    override fun acknowledge(id: Long) {
        if (id > prefs.getLong(CURSOR, Long.MIN_VALUE)) prefs.edit().putLong(CURSOR, id).apply()
    }

    /** Never goes backwards or repeats, even if the clock does. */
    @Synchronized
    private fun nextStamp(): Long {
        val stamp = maxOf(System.currentTimeMillis(), prefs.getLong(LAST_STAMP, 0) + 1)
        prefs.edit().putLong(LAST_STAMP, stamp).apply()
        return stamp
    }

    @Synchronized
    private fun initCursor(below: Long) {
        if (!prefs.contains(CURSOR)) prefs.edit().putLong(CURSOR, below - 1).apply()
    }

    private companion object {
        const val CURSOR = "acked_stamp" // not "acked_id": cursors from the row-id scheme must not be reused
        const val LAST_STAMP = "last_stamp"
        const val REPLAY_LIMIT = 200
    }
}
