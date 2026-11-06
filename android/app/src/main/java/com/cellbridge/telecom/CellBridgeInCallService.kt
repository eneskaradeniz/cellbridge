package com.cellbridge.telecom

import android.telecom.Call
import com.cellbridge.server.ControlService
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.util.Log
import android.telecom.VideoProfile
import com.cellbridge.domain.model.CallDirection
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.domain.model.CallStatus
import dagger.hilt.android.AndroidEntryPoint
import java.util.UUID
import javax.inject.Inject

/**
 * Bound by Telecom next to the stock dialer, which keeps the call screen (this service has no UI of its own and needs
 * MANAGE_ONGOING_CALLS); reports every call to [CallRepository] and carries out the iPhone's commands.
 */
@AndroidEntryPoint
class CellBridgeInCallService : InCallService() {
    @Inject lateinit var repository: CallRepository
    @Inject lateinit var registry: CallRegistry
    @Inject lateinit var wakeLock: CallWakeLock
    @Inject lateinit var inCallAudio: InCallAudio

    private val silencer by lazy { RingerSilencer.forContext(this) }
    private val ids = HashMap<Call, String>()
    private val main = Handler(Looper.getMainLooper())

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) = report(call, state)
    }

    override fun onCreate() {
        super.onCreate()
        // A call can start this process while the server is down (killed in the background): bring it up too.
        ControlService.start(this)
        silencer.restore() // a crash in the middle of a ringing call may have left Do Not Disturb on
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
    }

    override fun onCallRemoved(call: Call) {
        call.unregisterCallback(callback)
        report(call, Call.STATE_DISCONNECTED) // no-op if already reported
        ids.remove(call)?.let(registry::unregister)
        restoreRingerIfQuiet()
    }

    /** The phone may ring again once nothing is ringing. */
    private fun restoreRingerIfQuiet() {
        if (calls.none { stateOf(it) == Call.STATE_RINGING }) silencer.restore()
    }

    override fun onDestroy() {
        silencer.restore()
        inCallAudio.control = null
        wakeLock.setHeld(false)
        super.onDestroy()
    }

    /** Control-server commands arrive on Ktor threads; telecom calls are made on the main thread. */
    private fun handleFor(call: Call) = object : CallHandle {
        override fun answer() { main.post { call.answer(VideoProfile.STATE_AUDIO_ONLY) } }
        override fun reject() { main.post { call.reject(false, null) } }
        override fun hangup() { main.post { call.disconnect() } }
        /** CAPABILITY_HOLD: the call can currently be put on hold or taken off it. */
        override fun hold() { main.post { if (call.details.can(Call.Details.CAPABILITY_HOLD)) call.hold() } }
        override fun unhold() { main.post { if (call.details.can(Call.Details.CAPABILITY_HOLD)) call.unhold() } }
                override fun dtmf(digit: Char) {
            main.post {
                call.stopDtmfTone() // a digit still sounding from the one before
                call.playDtmfTone(digit)
                main.postDelayed({ call.stopDtmfTone() }, DTMF_MS)
            }
        }

        // silenceRinger() needs MODIFY_PHONE_STATE, which only the default dialer holds (the stock dialer has the role),
        // so the ringer is quietened through Do Not Disturb instead; without that access the phone keeps ringing.
        override fun silence() {
            main.post {
                if (!silencer.silence()) Log.w("CellBridgeInCall", "cannot silence the ringer: no Do Not Disturb access")
            }
        }
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
        restoreRingerIfQuiet()
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
        const val DTMF_MS = 150L
    }
}
