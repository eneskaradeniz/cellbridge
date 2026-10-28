package com.cellbridge.audio

import java.net.InetSocketAddress

/** The root audio daemon as seen by the app: relays one call's audio to a UDP peer. */
interface CallAudio {
    /** True when the daemon answers (or is already serving this app); false means control-only mode. */
    suspend fun isAvailable(): Boolean

    /** Starts downlink + uplink with [peer]; returns false if the daemon refused or is unreachable. */
    suspend fun start(peer: InetSocketAddress): Boolean

    /** Ends the relay; safe to call when nothing is running. */
    suspend fun stop()
}
