package com.cellbridge.ui

import android.text.format.DateUtils
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cellbridge.R
import com.cellbridge.history.CallLogEntry
import com.cellbridge.status.HostStatus
import com.cellbridge.status.sanitizeDial

/** The phone's own app: how the bridge is doing, a keypad to call from this phone, and the calls it has seen. */
@Composable
fun MainScreen(
    status: HostStatus?,
    pairingCode: String,
    pairingLink: String,
    initialNumber: String?,
    recents: List<CallLogEntry>,
    onCall: (String) -> Unit,
    roles: @Composable () -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(if (initialNumber != null) 1 else 0) }
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            TabRow(selectedTabIndex = tab, containerColor = Color.Transparent) {
                listOf(R.string.tab_status, R.string.tab_keypad, R.string.tab_recents).forEachIndexed { index, label ->
                    Tab(selected = tab == index, onClick = { tab = index }, text = { Text(stringResource(label)) })
                }
            }
            when (tab) {
                0 -> StatusScreen(status, pairingCode, pairingLink, roles)
                1 -> KeypadScreen(initialNumber.orEmpty(), onCall)
                else -> RecentsScreen(recents, onCall)
            }
        }
    }
}

@Composable
private fun KeypadScreen(initial: String, onCall: (String) -> Unit) {
    var number by rememberSaveable { mutableStateOf(sanitizeDial(initial)) }
    val keys = listOf("1" to "", "2" to "ABC", "3" to "DEF", "4" to "GHI", "5" to "JKL", "6" to "MNO", "7" to "PQRS", "8" to "TUV", "9" to "WXYZ", "*" to "", "0" to "+", "#" to "")
    Column(
        Modifier.fillMaxSize().padding(horizontal = 28.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceEvenly,
    ) {
        Text(number.ifEmpty { " " }, fontSize = 38.sp, fontWeight = FontWeight.Light, maxLines = 1, textAlign = TextAlign.Center)
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            keys.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                    row.forEach { (digit, letters) ->
                        FilledTonalButton(
                            onClick = { number = sanitizeDial(number + digit) },
                            modifier = Modifier.weight(1f).height(64.dp),
                            shape = RoundedCornerShape(20.dp),
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(digit, fontSize = 24.sp)
                                if (letters.isNotEmpty()) Text(letters, fontSize = 9.sp, letterSpacing = 1.sp)
                            }
                        }
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Box(Modifier.size(72.dp))
            Button(
                onClick = { onCall(number) },
                enabled = number.isNotEmpty(),
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2E7D32), contentColor = Color.White),
                modifier = Modifier.size(width = 120.dp, height = 64.dp),
            ) { Text(stringResource(R.string.keypad_call), fontSize = 16.sp) }
            Box(Modifier.size(72.dp), contentAlignment = Alignment.Center) {
                if (number.isNotEmpty()) TextButton(onClick = { number = number.dropLast(1) }) { Text("⌫", fontSize = 24.sp) }
            }
        }
    }
}

@Composable
private fun RecentsScreen(entries: List<CallLogEntry>, onCall: (String) -> Unit) {
    if (entries.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.recents_empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    val context = LocalContext.current
    LazyColumn(Modifier.fillMaxSize()) {
        items(entries, key = { it.id }) { entry ->
            Column(
                Modifier.fillMaxWidth().clickable(enabled = entry.number.isNotEmpty()) { onCall(entry.number) }.padding(horizontal = 20.dp, vertical = 12.dp),
            ) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        entry.name ?: entry.number.ifEmpty { stringResource(R.string.incall_unknown) },
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = if (entry.kind == "missed") Color(0xFFD6453D) else MaterialTheme.colorScheme.onBackground,
                    )
                    Text(
                        DateUtils.formatDateTime(context, entry.timestamp, DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_ALL),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 14.sp,
                    )
                }
                Text(
                    stringResource(
                        when (entry.kind) {
                            "incoming" -> R.string.kind_incoming
                            "outgoing" -> R.string.kind_outgoing
                            "missed" -> R.string.kind_missed
                            else -> R.string.kind_rejected
                        },
                    ) + if (entry.durationSeconds > 0) " · " + com.cellbridge.ui.formatElapsed(entry.durationSeconds * 1000L) else "",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 14.sp,
                )
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
        }
    }
}
