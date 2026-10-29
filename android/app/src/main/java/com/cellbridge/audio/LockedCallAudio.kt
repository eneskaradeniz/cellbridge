package com.cellbridge.audio

import android.content.Context
import android.net.wifi.WifiManager
import java.net.InetSocketAddress

/** Something held for as long as audio flows, so the radio is not allowed to nap between packets. */
interface LinkLock {
    fun acquire()
    fun release()
}

/**
 * Wi-Fi power saving delivers audio in bursts of 100-250 ms, which the jitter buffer then has to ride out. A low-latency
 * Wi-Fi lock asks the radio to stay awake; it is held only while a call's audio runs.
 */
class WifiLinkLock(context: Context) : LinkLock {
    private val lock = context.applicationContext.getSystemService(WifiManager::class.java)
        ?.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "cellbridge:call")
        ?.apply { setReferenceCounted(false) }

    override fun acquire() { lock?.takeIf { !it.isHeld }?.acquire() }

    override fun release() { lock?.takeIf { it.isHeld }?.release() }
}

/** Holds [link] while the wrapped audio relay is running. */
class LockedCallAudio(private val inner: CallAudio, private val link: LinkLock) : CallAudio {
    override suspend fun isAvailable(): Boolean = inner.isAvailable()

    override suspend fun start(peer: InetSocketAddress): Boolean {
        val started = inner.start(peer)
        if (started) link.acquire() else link.release()
        return started
    }

    override suspend fun stop() {
        try {
            inner.stop()
        } finally {
            link.release()
        }
    }
}
