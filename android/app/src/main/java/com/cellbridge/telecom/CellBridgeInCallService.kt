package com.cellbridge.telecom

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.cellbridge.R
import android.telecom.Call
import android.util.Log
import com.cellbridge.server.ControlService
import com.cellbridge.ui.InCallActivity
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import dagger.hilt.android.AndroidEntryPoint
import java.util.UUID
import javax.inject.Inject

/** Bound by Telecom while this app is the default dialer; reports every call to [CallRepository]. */
@AndroidEntryPoint
class CellBridgeInCallService : InCallService() {
    @Inject lateinit var repository: CallRepository
    @Inject lateinit var registry: CallRegistry
    @Inject lateinit var wakeLock: CallWakeLock
    @Inject lateinit var inCallAudio: InCallAudio

    private val ids = HashMap<Call, String>()
    private val main = Handler(Looper.getMainLooper())

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) = report(call, state)
    }

    override fun onCreate() {
        super.onCreate()
        // A call can start this process while the server is down (killed in the background): bring it up too.
        ControlService.start(this)
        inCallAudio.control = object : InCallAudioControl {
            override fun setMuted(muted: Boolean) { main.post { this@CellBridgeInCallService.setMuted(muted) } }

            @Suppress("DEPRECATION") // setAudioRoute is deprecated from API 34 but still the way on 29-33
            override fun setSpeaker(on: Boolean) {
                main.post { setAudioRoute(if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE) }
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onCallAudioStateChanged(audioState: CallAudioState) {
        inCallAudio.update(audioState.isMuted, audioState.route == CallAudioState.ROUTE_SPEAKER)
    }

    override fun onCallAdded(call: Call) {
        val id = UUID.randomUUID().toString()
        ids[call] = id
        registry.register(id, handleFor(call))
        call.registerCallback(callback)
        report(call, stateOf(call))
        showCallScreen()
    }

    private fun showCallScreen() {
        runCatching { startActivity(Intent(this, InCallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            .onFailure { Log.w(TAG, "call screen not shown: ${it::class.simpleName}") }
    }

    override fun onCallRemoved(call: Call) {
        call.unregisterCallback(callback)
        report(call, Call.STATE_DISCONNECTED) // no-op if already reported
        ids.remove(call)?.let(registry::unregister)
        if (!repository.hasLiveCalls) getSystemService(NotificationManager::class.java).cancel(CALL_NOTIFICATION_ID)
    }

    override fun onDestroy() {
        inCallAudio.control = null
        wakeLock.setHeld(false)
        super.onDestroy()
    }

    /** Control-server commands arrive on Ktor threads; telecom calls are made on the main thread. */
    private fun handleFor(call: Call) = object : CallHandle {
        override fun answer() { main.post { call.answer(VideoProfile.STATE_AUDIO_ONLY) } }
        override fun reject() { main.post { call.reject(false, null) } }
        override fun hangup() { main.post { call.disconnect() } }
        // The default dialer may silence the ringer; the call keeps ringing for the iPhone, only the phone stops making noise.
        override fun dtmf(digit: Char) {
            main.post {
                call.stopDtmfTone() // a digit still sounding from the one before
                call.playDtmfTone(digit)
                main.postDelayed({ call.stopDtmfTone() }, DTMF_MS)
            }
        }

        override fun silence() { main.post { getSystemService(TelecomManager::class.java)?.silenceRinger() } }
    }

    private fun report(call: Call, state: Int) {
        val id = ids[call] ?: return
        val status = statusOf(state) ?: return
        val direction = if (call.details.callDirection == Call.Details.DIRECTION_INCOMING) {
            CallDirection.INCOMING
        } else {
            CallDirection.OUTGOING
        }
        val number = call.details.handle?.schemeSpecificPart?.takeIf { it.isNotBlank() }
        val rejected = status == CallStatus.DISCONNECTED && call.details.disconnectCause?.code == DisconnectCause.REJECTED
        repository.onCallUpdate(CallSnapshot(id, number, direction, status, rejected, call.details.connectTimeMillis))
        wakeLock.setHeld(repository.hasLiveCalls)
        updateCallNotification(number, call.details.connectTimeMillis)
    }

    /** The way back to the call screen after it was left: an ongoing notification for as long as a call lives. */
    private fun updateCallNotification(number: String?, connectedAtMs: Long) {
        val manager = getSystemService(NotificationManager::class.java)
        if (!repository.hasLiveCalls) return manager.cancel(CALL_NOTIFICATION_ID)
        manager.createNotificationChannel(NotificationChannel(CALL_CHANNEL, getString(R.string.call_channel), NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, InCallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, CALL_CHANNEL)
            .setSmallIcon(android.R.drawable.sym_action_call)
            .setContentTitle(number ?: getString(R.string.incall_unknown))
            .setContentText(getString(R.string.call_notification_text))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setContentIntent(open)
            .apply { if (connectedAtMs > 0) setUsesChronometer(true).setWhen(connectedAtMs) }
            .build()
        manager.notify(CALL_NOTIFICATION_ID, notification)
    }

    @Suppress("DEPRECATION") // Call.Details.getState() needs API 31; minSdk is 29.
    private fun stateOf(call: Call): Int = call.state

    private fun statusOf(state: Int): CallStatus? = when (state) {
        Call.STATE_RINGING -> CallStatus.RINGING
        Call.STATE_NEW, Call.STATE_DIALING, Call.STATE_CONNECTING, Call.STATE_PULLING_CALL,
        Call.STATE_SELECT_PHONE_ACCOUNT -> CallStatus.DIALING
        Call.STATE_ACTIVE -> CallStatus.ACTIVE
        Call.STATE_HOLDING -> CallStatus.HOLDING
        Call.STATE_DISCONNECTED -> CallStatus.DISCONNECTED
        else -> null // DISCONNECTING: wait for DISCONNECTED
    }

    private companion object {
        const val TAG = "CellBridge"
        const val CALL_CHANNEL = "call"
        const val CALL_NOTIFICATION_ID = 2
        const val DTMF_MS = 150L
    }
}
