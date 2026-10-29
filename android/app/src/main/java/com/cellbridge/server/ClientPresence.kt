package com.cellbridge.server

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import javax.inject.Inject
import javax.inject.Singleton

/** How many authenticated clients are connected right now. */
@Singleton
class ClientPresence @Inject constructor() {
    private val count = MutableStateFlow(0)

    val connected: Boolean get() = count.value > 0

    /** For screens that show whether the iPhone is there. */
    val isConnected: StateFlow<Boolean> get() = _isConnected
    private val _isConnected = MutableStateFlow(false)

    private val _lastJoined = MutableStateFlow<Long?>(null)

    /** When a client last connected (ms since epoch); null if none did since the app started. */
    val lastJoinedMs: StateFlow<Long?> get() = _lastJoined

    fun joined() { count.update { it + 1 }; _isConnected.value = true; _lastJoined.value = System.currentTimeMillis() }

    fun left() { count.update { it - 1 }; _isConnected.value = count.value > 0 }
}
