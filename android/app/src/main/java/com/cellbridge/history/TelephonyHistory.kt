package com.cellbridge.history

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.content.pm.PackageManager
import android.provider.CallLog
import android.provider.Telephony
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/** Reads the system call log and SMS database. Both are readable for the default dialer / SMS app. */
@Singleton
class TelephonyHistory @Inject constructor(@ApplicationContext private val context: Context) : HistorySource {
    private val resolver = context.contentResolver

    override fun callsAvailable() =
        context.checkSelfPermission(Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED

    override suspend fun calls(afterId: Long, sinceMs: Long, limit: Int): List<CallLogEntry> = withContext(Dispatchers.IO) {
        if (!callsAvailable()) return@withContext emptyList()
        val columns = arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION)
        val result = mutableListOf<CallLogEntry>()
        newest(
            CallLog.Calls.CONTENT_URI, columns, "${CallLog.Calls._ID} > ? AND ${CallLog.Calls.DATE} >= ?",
            arrayOf(afterId.toString(), sinceMs.toString()), CallLog.Calls.DATE, limit,
        )?.use {
            while (it.moveToNext()) {
                val kind = callKind(it.getInt(3)) ?: continue
                result += CallLogEntry(it.getLong(0), it.getString(1).orEmpty(), it.getString(2), kind, it.getLong(4), it.getInt(5))
            }
        }
        result.reversed()
    }

    /**
     * The newest [limit] rows by [dateColumn]. The limit goes in the query arguments: Android 15's providers refuse a LIMIT written
     * into the sort order ("Invalid token LIMIT") for apps, whatever works from the shell.
     */
    private fun newest(uri: Uri, columns: Array<String>, selection: String, args: Array<String>, dateColumn: String, limit: Int): Cursor? {
        val query = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
            putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(dateColumn))
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
        }
        return resolver.query(uri, columns, query, null)
    }

    override suspend fun texts(sinceMs: Long, limit: Int): List<TextHistoryItem> = withContext(Dispatchers.IO) {
        val columns = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.DATE_SENT, Telephony.Sms.TYPE)
        val result = mutableListOf<TextHistoryItem>()
        runCatching {
            newest(
                Telephony.Sms.CONTENT_URI, columns, "${Telephony.Sms.DATE} >= ? AND ${Telephony.Sms.TYPE} IN (1, 2)",
                arrayOf(sinceMs.toString()), Telephony.Sms.DATE, limit,
            )?.use {
                while (it.moveToNext()) {
                    val outgoing = it.getInt(5) == Telephony.Sms.MESSAGE_TYPE_SENT
                    val date = it.getLong(3)
                    // An incoming text's id is its DATE stamp, like the live `sms` message; its time is when the sender sent it.
                    result += TextHistoryItem(
                        id = if (outgoing) "out-${it.getLong(0)}" else date.toString(),
                        peer = it.getString(1).orEmpty(), body = it.getString(2).orEmpty(),
                        timestamp = if (outgoing) date else it.getLong(4).takeIf { sent -> sent > 0 } ?: date,
                        outgoing = outgoing,
                    )
                }
            }
        }
        result.reversed()
    }
}
