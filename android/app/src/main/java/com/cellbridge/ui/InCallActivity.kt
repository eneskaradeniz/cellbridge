package com.cellbridge.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cellbridge.R
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.telecom.CallCommands
import com.cellbridge.telecom.CallFeed
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.delay
import javax.inject.Inject

/**
 * The phone's own call screen. The iPhone is the normal way to handle calls, but as the default dialer this app is
 * the only call UI the phone has: without it a call could not be answered or ended on the phone itself.
 */
@AndroidEntryPoint
class InCallActivity : ComponentActivity() {
    @Inject lateinit var feed: CallFeed
    @Inject lateinit var commands: CallCommands

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                val calls by produceState(feed.liveCalls()) { feed.events.collect { value = feed.liveCalls() } }
                LaunchedEffect(calls) { if (calls.isEmpty()) finish() }
                primaryCall(calls)?.let { InCallScreen(it, commands) }
            }
        }
    }
}

@Composable
private fun InCallScreen(call: CallSnapshot, commands: CallCommands) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val activeSince = remember(call.id) { System.currentTimeMillis() }
    LaunchedEffect(Unit) { while (true) { delay(1_000); now = System.currentTimeMillis() } }
    val phase = phaseOf(call)

    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.safeDrawingPadding().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(top = 64.dp)) {
                Text(call.number ?: stringResource(R.string.incall_unknown), fontSize = 34.sp)
                Text(
                    when (phase) {
                        CallPhase.INCOMING -> stringResource(R.string.incall_incoming)
                        CallPhase.DIALING -> stringResource(R.string.incall_dialing)
                        CallPhase.HOLDING -> stringResource(R.string.incall_holding)
                        CallPhase.ACTIVE -> stringResource(R.string.incall_active) + "  " + formatElapsed(now - activeSince)
                    },
                    fontSize = 18.sp,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(48.dp), modifier = Modifier.padding(bottom = 48.dp)) {
                if (phase == CallPhase.INCOMING) {
                    CallButton(stringResource(R.string.incall_reject), Color(0xFFD32F2F)) { commands.reject(call.id) }
                    CallButton(stringResource(R.string.incall_answer), Color(0xFF2E7D32)) { commands.answer(call.id) }
                } else {
                    CallButton(stringResource(R.string.incall_end), Color(0xFFD32F2F)) { commands.hangup(call.id) }
                }
            }
        }
    }
}

@Composable
private fun CallButton(label: String, color: Color, onClick: () -> Unit) {
    Button(onClick = onClick, colors = ButtonDefaults.buttonColors(containerColor = color, contentColor = Color.White), modifier = Modifier.size(width = 120.dp, height = 64.dp)) {
        Text(label, fontSize = 16.sp)
    }
}
