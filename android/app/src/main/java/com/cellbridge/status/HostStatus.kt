package com.cellbridge.status

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.telephony.TelephonyManager
import com.cellbridge.audio.CallAudioBridge
import com.cellbridge.push.PushNotifier
import com.cellbridge.server.ClientPresence
import com.cellbridge.server.ControlServer
import dagger.hilt.android.qualifiers.ApplicationContext
import java.net.Inet4Address
import java.net.NetworkInterface
import javax.inject.Inject
import javax.inject.Singleton

data class AddressInfo(val label: String, val address: String)

/** What the phone's main screen reports about the bridge. */
data class HostStatus(
    val serverRunning: Boolean,
    val iphoneConnected: Boolean,
    val lastConnectedAtMs: Long?,
    val audioReady: Boolean,
    val addresses: List<AddressInfo>,
    val batteryPercent: Int?,
    val charging: Boolean,
    val pushKey: Boolean,
    val pushToken: Boolean,
)

/** A name a person recognises for an interface; null for the ones the iPhone can never reach (mobile data, loopback). */
fun interfaceLabel(name: String): String? = when {
    name.startsWith("wlan") -> "Wi-Fi"
    name.startsWith("ap") || name.startsWith("swlan") -> "Hotspot"
    name.startsWith("eth") || name.startsWith("usb") || name.startsWith("rndis") -> name
    else -> null
}

/** Private IPv4 ranges only: the address the iPhone types has to be one on the local network. */
fun isLocalNetwork(address: String): Boolean {
    val parts = address.split(".").mapNotNull { it.toIntOrNull() }
    if (parts.size != 4) return false
    return parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) || (parts[0] == 192 && parts[1] == 168)
}

fun pickAddresses(interfaces: List<Pair<String, String>>): List<AddressInfo> =
    interfaces.mapNotNull { (name, address) ->
        val label = interfaceLabel(name) ?: return@mapNotNull null
        if (isLocalNetwork(address)) AddressInfo(label, address) else null
    }.distinct()

/** What the iPhone is told about the phone (`host_status`). */
data class PhoneStatus(val battery: Int?, val charging: Boolean, val signal: Int?, val operator: String?)

fun interface PhoneStatusSource {
    suspend fun phone(): PhoneStatus?
}

object NoPhoneStatus : PhoneStatusSource {
    override suspend fun phone(): PhoneStatus? = null
}

@Singleton
class HostStatusReader @Inject constructor(
    @ApplicationContext private val context: Context,
    private val presence: ClientPresence,
    private val server: dagger.Lazy<ControlServer>,
    private val audio: CallAudioBridge,
    private val push: PushNotifier,
) : PhoneStatusSource {
    override suspend fun phone(): PhoneStatus? = phoneStatus()

    suspend fun read(): HostStatus {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return HostStatus(
            serverRunning = server.get().running.value,
            iphoneConnected = presence.connected,
            lastConnectedAtMs = presence.lastJoinedMs.value,
            audioReady = runCatching { audio.isAvailable() }.getOrDefault(false),
            addresses = pickAddresses(localAddresses()),
            batteryPercent = if (level >= 0 && scale > 0) level * 100 / scale else null,
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
            pushKey = push.available(),
            pushToken = push.hasToken(),
        )
    }

    /** Battery and cellular state for the iPhone; nothing here needs the network. */
    fun phoneStatus(): PhoneStatus {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val telephony = context.getSystemService(TelephonyManager::class.java)
        val signal = runCatching { telephony?.signalStrength?.level }.getOrNull()
        return PhoneStatus(
            battery = if (level >= 0 && scale > 0) level * 100 / scale else null,
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
            signal = signal,
            operator = telephony?.networkOperatorName?.takeIf { it.isNotBlank() },
        )
    }

    private fun localAddresses(): List<Pair<String, String>> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { nic ->
            nic.inetAddresses.toList().filterIsInstance<Inet4Address>().map { nic.name to (it.hostAddress ?: "") }
        }
    }.getOrDefault(emptyList())
}
