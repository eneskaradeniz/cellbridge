package com.cellbridge.server

import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton

/** How many authenticated clients are connected right now. */
@Singleton
class ClientPresence @Inject constructor() {
    private val count = AtomicInteger()

    val connected: Boolean get() = count.get() > 0

    fun joined() { count.incrementAndGet() }

    fun left() { count.decrementAndGet() }
}
