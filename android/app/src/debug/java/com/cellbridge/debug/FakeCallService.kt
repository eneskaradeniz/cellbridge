package com.cellbridge.debug

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager

/**
 * Debug-only stand-in for the cellular network: lets `adb` raise an incoming call that travels through the
 * real Telecom stack, so [com.cellbridge.telecom.CellBridgeInCallService] sees it like any other call.
 * The disconnect causes reported here are ours, not the radio's.
 */
class FakeCallService : ConnectionService() {
    override fun onCreateIncomingConnection(
        account: PhoneAccountHandle?,
        request: ConnectionRequest,
    ): Connection = FakeConnection(request.address).also {
        current = it
        it.setRinging()
    }

    /** A call placed through the fake account rings "remotely" for a moment and is then answered. */
    override fun onCreateOutgoingConnection(account: PhoneAccountHandle?, request: ConnectionRequest): Connection =
        FakeConnection(request.address).also { connection ->
            current = connection
            connection.setDialing()
            Handler(Looper.getMainLooper()).postDelayed({
                if (connection.state == Connection.STATE_DIALING) connection.setActive()
            }, ANSWER_DELAY_MS)
        }

    class FakeConnection(address: Uri?) : Connection() {
        init {
            setAddress(address, TelecomManager.PRESENTATION_ALLOWED)
            connectionCapabilities = CAPABILITY_HOLD
        }

        override fun onAnswer() = setActive()

        override fun onAnswer(videoState: Int) = setActive()

        override fun onReject() = finish(DisconnectCause.REJECTED)

        override fun onDisconnect() = finish(DisconnectCause.LOCAL)

        /** The far end hangs up: a call nobody answered counts as missed. */
        fun hangUpRemotely() = finish(if (state == STATE_RINGING) DisconnectCause.MISSED else DisconnectCause.REMOTE)

        private fun finish(cause: Int) {
            setDisconnected(DisconnectCause(cause))
            destroy()
            if (current === this) current = null
        }
    }

    companion object {
        private const val ACCOUNT_ID = "fake"
        private const val ANSWER_DELAY_MS = 1_500L
        var current: FakeConnection? = null

        fun register(context: Context): PhoneAccountHandle {
            val handle = PhoneAccountHandle(ComponentName(context, FakeCallService::class.java), ACCOUNT_ID)
            val account = PhoneAccount.builder(handle, "CellBridge fake")
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
                .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
                .build()
            context.getSystemService(TelecomManager::class.java).registerPhoneAccount(account)
            return handle
        }
    }
}
