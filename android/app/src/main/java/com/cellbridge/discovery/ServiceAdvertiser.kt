package com.cellbridge.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
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
class ServiceAdvertiser @Inject constructor(@ApplicationContext context: Context, private val deviceId: DeviceId) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    @Synchronized
    fun start(port: Int) {
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
        listener?.let { runCatching { manager.unregisterService(it) } }
        listener = null
    }

    private companion object {
        const val TAG = "CellBridge"
    }
}
