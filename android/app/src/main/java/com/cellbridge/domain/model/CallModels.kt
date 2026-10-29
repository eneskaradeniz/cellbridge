package com.cellbridge.domain.model

enum class CallDirection { INCOMING, OUTGOING }

/** Platform-independent call states; DISCONNECTED is terminal. */
enum class CallStatus { RINGING, DIALING, ACTIVE, HOLDING, DISCONNECTED }

/**
 * One observation of a telecom call. [id] is stable for the lifetime of the call and is what the
 * iOS client refers to (`callId` in docs/protocol.md). [number] is null for private/unknown callers.
 */
data class CallSnapshot(
    val id: String,
    val number: String?,
    val direction: CallDirection,
    val status: CallStatus,
    /** Only meaningful once DISCONNECTED: the platform says this side declined the call. */
    val rejected: Boolean = false,
    /** When the call connected (platform clock, ms), 0 while it has not. */
    val connectedAtMs: Long = 0,
)

/** Why an incoming call ended without being answered. */
enum class EndReason { MISSED, REJECTED }

/** What a call's progress means for the client; at most one event per real transition. */
sealed interface CallEvent {
    val call: CallSnapshot

    data class Ringing(override val call: CallSnapshot) : CallEvent
    data class Dialing(override val call: CallSnapshot) : CallEvent
    data class Answered(override val call: CallSnapshot) : CallEvent

    /** [reason] is null for a call that was answered (or an outgoing one). */
    data class Ended(override val call: CallSnapshot, val reason: EndReason?) : CallEvent
}
