package com.cellbridge.discovery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/** Where the iPhone finds the phone on the local network (Bonjour / mDNS): `_cellbridge._tcp`, so no address has to be typed. */
const val SERVICE_TYPE = "_cellbridge._tcp"

/** A random id that stays with this installation. It names the phone, it is not a secret and is not derived from the pairing code. */
@Singleton
class DeviceId @Inject constructor(@ApplicationContext context: Context) {
    val value: String = File(context.filesDir, "device_id").let { file ->
        runCatching { file.readText().trim() }.getOrNull()?.takeIf { it.length >= 8 }
            ?: UUID.randomUUID().toString().also { runCatching { file.writeText(it) } }
    }
}

@Singleton
class ServiceAdvertiser @Inject constructor(@ApplicationContext private val context: Context, private val deviceId: DeviceId) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null
    private var port = 0
    private var multicastLock: WifiManager.MulticastLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val reregister = Runnable { restart() }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = networkChanged()
        override fun onLost(network: Network) = networkChanged()
    }
    private val hotspotReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = networkChanged()
    }

    /** The network changed (hotspot toggled, Wi-Fi joined or left): the registration is for the old one, so make it again. */
    private fun networkChanged() {
        handler.removeCallbacks(reregister)
        handler.postDelayed(reregister, 1500) // changes arrive in bursts
    }

    @Synchronized
    private fun restart() {
        if (port == 0) return
        Log.i(TAG, "network changed, advertising again")
        unregister()
        register()
    }

    @Synchronized
    fun start(port: Int) {
        if (this.port != 0) return
        this.port = port
        multicastLock = context.getSystemService(WifiManager::class.java)
            ?.createMulticastLock("cellbridge-mdns")?.apply { setReferenceCounted(false); acquire() }
        runCatching {
            context.getSystemService(ConnectivityManager::class.java).registerNetworkCallback(NetworkRequest.Builder().build(), networkCallback)
            context.registerReceiver(hotspotReceiver, IntentFilter("android.net.wifi.WIFI_AP_STATE_CHANGED"), Context.RECEIVER_EXPORTED)
        }.onFailure { Log.w(TAG, "network watch failed", it) }
        register()
    }

    private fun register() {
        if (listener != null) return
        val info = NsdServiceInfo().apply {
            serviceName = "CellBridge"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", "1")
            setAttribute("id", deviceId.value)
        }
        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { Log.i(TAG, "advertising as ${info.serviceName}") }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) { Log.w(TAG, "advertising failed: $errorCode"); listener = null }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        listener = registration
        runCatching { manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration) }
            .onFailure { Log.w(TAG, "advertising failed", it); listener = null }
    }

    @Synchronized
    fun stop() {
        if (port == 0) return
        port = 0
        handler.removeCallbacks(reregister)
        runCatching { context.getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback) }
        runCatching { context.unregisterReceiver(hotspotReceiver) }
        multicastLock?.let { runCatching { it.release() } }
        multicastLock = null
        unregister()
    }

    private fun unregister() {
        listener?.let { runCatching { manager.unregisterService(it) } }
        listener = null
    }

    private companion object {
        const val TAG = "CellBridge"
    }
}
