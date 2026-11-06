package com.cellbridge.telecom

import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

/** What the client can ask of a call. Implementations must be safe to call from any thread. */
interface CallHandle {
    fun answer()
    fun reject()
    fun hangup()

    /** Stops the phone from ringing (and vibrating) for this call without answering it. */
    fun silence()

    /** Plays one keypad tone (0-9, *, #) into the call. */
    fun dtmf(digit: Char)

    /** Puts the call on hold at the network (the other party hears the hold tone) and takes it off again. */
    fun hold()
    fun unhold()
}

/** Client commands addressed by call id; each returns false when no such call is live. */
interface CallCommands {
    fun answer(callId: String): Boolean
    fun reject(callId: String): Boolean
    fun hangup(callId: String): Boolean
    fun silence(callId: String): Boolean
    fun dtmf(callId: String, digit: Char): Boolean
    fun hold(callId: String): Boolean
    fun unhold(callId: String): Boolean
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

    override fun silence(callId: String) = handles[callId]?.silence() != null

    override fun dtmf(callId: String, digit: Char) = handles[callId]?.dtmf(digit) != null

    override fun hold(callId: String) = handles[callId]?.hold() != null

    override fun unhold(callId: String) = handles[callId]?.unhold() != null
}
