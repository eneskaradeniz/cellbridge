package com.cellbridge.ui

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cellbridge.R
import com.cellbridge.status.HostStatus
import com.cellbridge.status.qrModules
import kotlinx.coroutines.delay
import java.util.Date

private val Good = Color(0xFF2E9E6B)
private val Warn = Color(0xFFE0922F)
private val Bad = Color(0xFFD6453D)

/** The phone's main screen: is the bridge up, where to point the iPhone, is everything it needs in place. */
@Composable
fun StatusScreen(status: HostStatus?, pairingCode: String, pairingLink: String, onUnrestrict: () -> Unit, autoHotspot: Boolean, onAutoHotspot: (Boolean) -> Unit, roles: @Composable () -> Unit) {
    run {
        Column(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
            if (status == null) return@Column

            Section(stringResource(R.string.card_iphone)) {
                Line(
                    if (status.iphoneConnected) stringResource(R.string.iphone_connected) else stringResource(R.string.iphone_not_connected),
                    if (status.iphoneConnected) Good else Bad,
                )
                Detail(
                    status.lastConnectedAtMs?.let { stringResource(R.string.last_connected, clock(it)) } ?: stringResource(R.string.never_connected),
                )
                Line(
                    stringResource(if (status.serverRunning) R.string.server_running else R.string.server_stopped),
                    if (status.serverRunning) Good else Bad,
                )
            }

            Section(stringResource(R.string.card_network)) {
                if (status.addresses.isEmpty()) {
                    Line(stringResource(R.string.no_network), Warn)
                } else {
                    status.addresses.forEach { Row(Modifier.fillMaxWidth(), Arrangement.SpaceBetween) {
                        Text(it.label, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        SelectionContainer { Text(it.address, fontFamily = FontFamily.Monospace, fontSize = 17.sp) }
                    } }
                }
            }

            Section(stringResource(R.string.card_audio)) {
                Line(
                    if (status.audioReady) stringResource(R.string.audio_ready) else stringResource(R.string.audio_missing),
                    if (status.audioReady) Good else Warn,
                )
            }

            Section(stringResource(R.string.card_push)) {
                when {
                    !status.pushKey -> Line(stringResource(R.string.push_key_missing), Warn)
                    !status.pushToken -> Line(stringResource(R.string.push_token_missing), Warn)
                    else -> Line(stringResource(R.string.push_ready), Good)
                }
            }

            Section(stringResource(R.string.card_battery)) {
                Line(
                    status.batteryPercent?.let { "%$it" + if (status.charging) " · " + stringResource(R.string.charging) else "" } ?: "?",
                    when {
                        status.charging -> Good
                        (status.batteryPercent ?: 100) < 20 -> Bad
                        (status.batteryPercent ?: 100) < 40 -> Warn
                        else -> Good
                    },
                )
            }

            Section(stringResource(R.string.card_unrestricted)) {
                if (status.unrestricted) {
                    Line(stringResource(R.string.unrestricted_ok), Good)
                } else {
                    Line(stringResource(R.string.unrestricted_missing), Warn)
                    TextButton(onClick = onUnrestrict) { Text(stringResource(R.string.unrestricted_ask)) }
                }
            }

            Section(stringResource(R.string.card_hotspot)) {
                Row(Modifier.fillMaxWidth(), Arrangement.SpaceBetween, Alignment.CenterVertically) {
                    Text(stringResource(R.string.hotspot_auto), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                    Switch(checked = autoHotspot, onCheckedChange = onAutoHotspot)
                }
                Detail(stringResource(R.string.hotspot_hint))
            }

            Section(stringResource(R.string.card_roles)) { roles() }

            Section(stringResource(R.string.card_pairing)) { PairingCode(pairingCode, pairingLink) }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            content()
        }
    }
}

@Composable
private fun Line(text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(10.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun Detail(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp))
}

/** Hidden until asked for, and hidden again after ten seconds: it is the key to the phone's calls and texts. */
@Composable
private fun PairingCode(code: String, link: String) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(shown) { if (shown) { delay(10_000); shown = false } }
    Row(Modifier.fillMaxWidth(), Arrangement.SpaceBetween, Alignment.CenterVertically) {
        if (shown) {
            SelectionContainer { Text(code, fontFamily = FontFamily.Monospace, fontSize = 26.sp, letterSpacing = 3.sp) }
        } else {
            Text("•".repeat(code.length), fontSize = 26.sp, letterSpacing = 3.sp)
        }
        TextButton(onClick = { shown = !shown }) { Text(stringResource(if (shown) R.string.hide_code else R.string.show_code)) }
    }
    Detail(stringResource(R.string.pairing_hint))
    if (shown) QrCode(link)
}

/** The pairing link as a QR code, dark modules on white so any camera reads it in either theme. */
@Composable
private fun QrCode(link: String) {
    val modules = remember(link) { qrModules(link) }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(240.dp).clip(RoundedCornerShape(12.dp)).background(Color.White).padding(14.dp)) {
            val cell = size.width / modules.size
            modules.forEachIndexed { y, row ->
                row.forEachIndexed { x, dark ->
                    if (dark) drawRect(Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
                }
            }
        }
    }
}

@Composable
private fun clock(ms: Long): String = DateFormat.getTimeFormat(LocalContext.current).format(Date(ms))
