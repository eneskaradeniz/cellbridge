package com.cellbridge.sms

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject

/** Sends through the radio and waits until the platform reports every part as sent (or refused). */
class PlatformSmsSender @Inject constructor(@ApplicationContext private val context: Context) : SmsSender {
    private val sequence = AtomicInteger()

    override suspend fun send(to: String, body: String): Boolean {
        val manager = smsManager()
        val parts = manager.divideMessage(body)
        val action = "com.cellbridge.SMS_SENT.${sequence.incrementAndGet()}"
        val remaining = AtomicInteger(parts.size)
        val allSent = AtomicBoolean(true)
        val done = CompletableDeferred<Boolean>()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (resultCode != Activity.RESULT_OK) allSent.set(false)
                if (remaining.decrementAndGet() == 0) done.complete(allSent.get())
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        return try {
            val sentIntent = PendingIntent.getBroadcast(
                context, 0, Intent(action).setPackage(context.packageName), PendingIntent.FLAG_IMMUTABLE,
            )
            manager.sendMultipartTextMessage(to, null, parts, ArrayList(parts.map { sentIntent }), null)
            withTimeoutOrNull(SEND_TIMEOUT_MS) { done.await() } ?: false
        } catch (e: RuntimeException) {
            false
        } finally {
            context.unregisterReceiver(receiver)
        }
    }

    @Suppress("DEPRECATION") // getSystemService(SmsManager) needs API 31; minSdk is 29.
    private fun smsManager(): SmsManager =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) context.getSystemService(SmsManager::class.java) else SmsManager.getDefault()

    private companion object {
        const val SEND_TIMEOUT_MS = 60_000L
    }
}
