package com.cellbridge.domain.model

/** A received text. [id] is the system SMS database row id; the client acknowledges by it. */
data class IncomingSms(val id: Long, val from: String, val body: String, val timestamp: Long)

sealed interface SendResult {
    data object Sent : SendResult
    data class Failed(val error: String) : SendResult
}
