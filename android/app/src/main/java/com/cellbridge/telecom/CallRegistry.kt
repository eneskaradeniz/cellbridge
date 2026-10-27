package com.cellbridge.telecom

import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/** What the client can ask of a call. Implementations must be safe to call from any thread. */
interface CallHandle {
    fun answer()
    fun reject()
    fun hangup()
}

/** Client commands addressed by call id; each returns false when no such call is live. */
interface CallCommands {
    fun answer(callId: String): Boolean
    fun reject(callId: String): Boolean
    fun hangup(callId: String): Boolean
}

/** Maps call ids to the live telecom calls so control-server commands can reach them. */
@Singleton
class CallRegistry @Inject constructor() : CallCommands {
    private val handles = ConcurrentHashMap<String, CallHandle>()

    fun register(callId: String, handle: CallHandle) {
        handles[callId] = handle
    }

    fun unregister(callId: String) {
        handles.remove(callId)
    }

    override fun answer(callId: String) = handles[callId]?.answer() != null

    override fun reject(callId: String) = handles[callId]?.reject() != null

    override fun hangup(callId: String) = handles[callId]?.hangup() != null
}
