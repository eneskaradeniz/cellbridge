package com.cellbridge.server

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/** The pairing secret a client must present in `hello`; generated once and kept in app-private storage. */
@Singleton
class PairingToken @Inject constructor(@ApplicationContext context: Context) {
    private val prefs = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    private val file = File(context.filesDir, DAEMON_FILE)

    val value: String by lazy {
        (prefs.getString(KEY, null) ?: generate().also { prefs.edit().putString(KEY, it).apply() })
            .also(::shareWithDaemon)
    }

    /**
     * The root audio daemon authenticates the app with this token. It reads it from a file (`serve @<path>`) so that
     * a daemon started by init at boot follows the token without being given it; only the app and root can read it.
     */
    private fun shareWithDaemon(token: String) {
        runCatching { if (!file.exists() || file.readText().trim() != token) file.writeText(token) }
    }

    private fun generate(): String {
        val random = SecureRandom()
        return String(CharArray(LENGTH) { ALPHABET[random.nextInt(ALPHABET.length)] })
    }

    private companion object {
        const val KEY = "token"
        const val DAEMON_FILE = "daemon.token"
        const val LENGTH = 8
        const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ" // no 0/O/1/I to read it off a screen
    }
}
