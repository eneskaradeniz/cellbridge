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
)

/** What a call's progress means for the client; at most one event per real transition. */
sealed interface CallEvent {
    val call: CallSnapshot

    data class Ringing(override val call: CallSnapshot) : CallEvent
    data class Dialing(override val call: CallSnapshot) : CallEvent
    data class Answered(override val call: CallSnapshot) : CallEvent

    /** [missed] is true for an incoming call that ended without ever being answered. */
    data class Ended(override val call: CallSnapshot, val missed: Boolean) : CallEvent
}
