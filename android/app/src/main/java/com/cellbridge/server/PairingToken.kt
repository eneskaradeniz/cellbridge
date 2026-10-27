package com.cellbridge.server

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.security.SecureRandom
import javax.inject.Inject
import javax.inject.Singleton

/** The pairing secret a client must present in `hello`; generated once and kept in app-private storage. */
@Singleton
class PairingToken @Inject constructor(@ApplicationContext context: Context) {
    private val prefs = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    val value: String by lazy {
        prefs.getString(KEY, null) ?: generate().also { prefs.edit().putString(KEY, it).apply() }
    }

    private fun generate(): String {
        val random = SecureRandom()
        return String(CharArray(LENGTH) { ALPHABET[random.nextInt(ALPHABET.length)] })
    }

    private companion object {
        const val KEY = "token"
        const val LENGTH = 8
        const val ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ" // no 0/O/1/I to read it off a screen
    }
}
