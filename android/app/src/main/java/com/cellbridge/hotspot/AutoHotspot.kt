package com.cellbridge.hotspot

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.PowerManager
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/** What survives a restart of the app: the user's switch, and whether the running hotspot is one this app started. */
interface HotspotStore {
    var enabled: Boolean
    var started: Boolean
}

/**
 * Away from the home Wi-Fi the iPhone has nothing to join, so the phone's hotspot is switched on; back on the home Wi-Fi it is
 * switched off again. Only a hotspot this app started is ever stopped: one switched on by hand stays. A short Wi-Fi blip (moving
 * between the 2.4 and 5 GHz networks) does nothing: the phone must still be away after [graceMs].
 */
class AutoHotspotLogic(
    private val daemon: WifiDaemon,
    private val store: HotspotStore,
    private val graceMs: Long = 30_000,
    private val retryMs: Long = 20_000,
    private val attempts: Int = 3,
) {
    suspend fun reconcile() {
        repeat(attempts) {
            val now = daemon.networks()
            if (now != null) {
                if (!store.enabled || now.atHome) return stopIfStarted()
                delay(graceMs)
                val later = daemon.networks()
                if (later != null) {
                    if (!store.enabled || later.atHome) return stopIfStarted()
                    if (store.started || switchHotspot(true)) {
                        store.started = true
                        return
                    }
                }
            }
            delay(retryMs) // the daemon is busy (a call) or still starting
        }
    }

    private suspend fun stopIfStarted() {
        if (store.started && switchHotspot(false)) store.started = false
    }

    /** A newer Wi-Fi change must not abandon a switch half way: the daemon finishes it, so the answer is still recorded. */
    private suspend fun switchHotspot(on: Boolean) = withContext(NonCancellable) { daemon.hotspot(on) }
}

/** Watches the Wi-Fi and runs [AutoHotspotLogic] after every change, with the CPU kept awake while it decides. */
@Singleton
class AutoHotspot @Inject constructor(
    @ApplicationContext private val context: Context,
    private val daemon: WifiDaemon,
) : HotspotStore {
    private val prefs = context.getSharedPreferences("auto_hotspot", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val logic = AutoHotspotLogic(daemon, this)
    private var job: Job? = null

    private val _enabled = MutableStateFlow(prefs.getBoolean(ENABLED, true))
    val enabledFlow: StateFlow<Boolean> = _enabled

    override var enabled: Boolean
        get() = _enabled.value
        set(value) {
            prefs.edit().putBoolean(ENABLED, value).apply()
            _enabled.value = value
        }

    override var started: Boolean
        get() = prefs.getBoolean(STARTED, false)
        set(value) = prefs.edit().putBoolean(STARTED, value).apply()

    fun switchAuto(on: Boolean) {
        enabled = on
        check()
    }

    /** Once per process; a Wi-Fi network coming or going (this phone's own hotspot is not one) re-checks. */
    fun start() {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        runCatching {
            connectivity.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = check()
                override fun onLost(network: Network) = check()
            })
        }.onFailure { Log.w("CellBridge", "wifi watch not started: ${it::class.simpleName}") }
        check()
    }

    private fun check() {
        job?.cancel()
        job = scope.launch {
            val lock = context.getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cellbridge:auto-hotspot")
            lock.acquire(WAKE_LIMIT_MS)
            try {
                logic.reconcile()
            } finally {
                if (lock.isHeld) lock.release()
            }
        }
    }

    private companion object {
        const val ENABLED = "enabled"
        const val STARTED = "started"
        const val WAKE_LIMIT_MS = 3 * 60_000L
    }
}
