package com.cellbridge.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cellbridge.R
import com.cellbridge.audio.CallAudioBridge
import com.cellbridge.domain.model.CallSnapshot
import com.cellbridge.server.ClientPresence
import com.cellbridge.server.TransferController
import com.cellbridge.telecom.CallCommands
import com.cellbridge.telecom.CallFeed
import com.cellbridge.telecom.InCallAudio
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * The phone's own call screen. The iPhone is the normal way to handle calls, but as the default dialer this app is
 * the only call UI the phone has: without it a call could not be answered, ended or moved on the phone itself.
 */
@AndroidEntryPoint
class InCallActivity : ComponentActivity() {
    @Inject lateinit var feed: CallFeed
    @Inject lateinit var commands: CallCommands
    @Inject lateinit var bridge: CallAudioBridge
    @Inject lateinit var transfers: TransferController
    @Inject lateinit var inCallAudio: InCallAudio
    @Inject lateinit var presence: ClientPresence

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                val calls by produceState(feed.liveCalls()) { feed.events.collect { value = feed.liveCalls() } }
                LaunchedEffect(calls) { if (calls.isEmpty()) finish() }
                val bridged by bridge.bridged.collectAsState()
                val audio by inCallAudio.state.collectAsState()
                val iphoneThere by presence.isConnected.collectAsState()
                val scope = rememberCoroutineScope()
                primaryCall(calls)?.let { call ->
                    InCallScreen(
                        call = call,
                        onIphone = call.id in bridged,
                        iphoneThere = iphoneThere,
                        muted = audio.muted,
                        speaker = audio.speaker,
                        actions = CallActions(
                            answer = { commands.answer(call.id) },
                            reject = { commands.reject(call.id) },
                            hangup = { commands.hangup(call.id) },
                            toggleMute = { inCallAudio.setMuted(!audio.muted) },
                            toggleSpeaker = { inCallAudio.setSpeaker(!audio.speaker) },
                            toIphone = { transfers.toIphone(call.id) },
                            toPhone = { scope.launch { transfers.toPhone(call.id) } },
                            dtmf = { commands.dtmf(call.id, it) },
                        ),
                    )
                }
            }
        }
    }
}

class CallActions(
    val answer: () -> Unit,
    val reject: () -> Unit,
    val hangup: () -> Unit,
    val toggleMute: () -> Unit,
    val toggleSpeaker: () -> Unit,
    val toIphone: () -> Unit,
    val toPhone: () -> Unit,
    val dtmf: (Char) -> Unit,
)

@Composable
private fun InCallScreen(
    call: CallSnapshot,
    onIphone: Boolean,
    iphoneThere: Boolean,
    muted: Boolean,
    speaker: Boolean,
    actions: CallActions,
) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val openedAt = remember(call.id) { System.currentTimeMillis() }
    val activeSince = call.connectedAtMs.takeIf { it > 0 } ?: openedAt
    LaunchedEffect(Unit) { while (true) { delay(1_000); now = System.currentTimeMillis() } }
    val phase = phaseOf(call)
    var keypad by remember(call.id) { mutableStateOf(false) }

    Surface(modifier = Modifier.fillMaxSize(), color = Color(0xFF0A1A22), contentColor = Color.White) {
        Column(
            modifier = Modifier.safeDrawingPadding().padding(horizontal = 28.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(top = 56.dp)) {
                if (onIphone) {
                    Text(
                        stringResource(R.string.incall_on_iphone),
                        color = Color(0xFF7FD6C2),
                        fontSize = 14.sp,
                        modifier = Modifier.clip(RoundedCornerShape(50)).background(Color(0x3322A68C)).padding(horizontal = 14.dp, vertical = 6.dp),
                    )
                    Spacer(Modifier.height(20.dp))
                }
                Text(call.number ?: stringResource(R.string.incall_unknown), fontSize = 34.sp, textAlign = TextAlign.Center)
                Text(
                    when (phase) {
                        CallPhase.INCOMING -> stringResource(R.string.incall_incoming)
                        CallPhase.DIALING -> stringResource(R.string.incall_dialing)
                        CallPhase.HOLDING -> stringResource(R.string.incall_holding)
                        CallPhase.ACTIVE -> formatElapsed(now - activeSince)
                    },
                    fontSize = 20.sp,
                    color = Color(0xFFB5C4CC),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }

            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(28.dp)) {
                if (keypad && (phase == CallPhase.ACTIVE || phase == CallPhase.HOLDING)) {
                    DialPad(actions.dtmf)
                    Toggle(stringResource(R.string.incall_hide_keypad), false, { keypad = false }, Modifier.fillMaxWidth())
                } else if (phase == CallPhase.ACTIVE || phase == CallPhase.HOLDING) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                        Toggle(stringResource(R.string.incall_mute), muted, actions.toggleMute, Modifier.weight(1f))
                        Toggle(stringResource(R.string.incall_speaker), speaker, actions.toggleSpeaker, Modifier.weight(1f))
                        Toggle(stringResource(R.string.incall_keypad), false, { keypad = true }, Modifier.weight(1f))
                    }
                    when {
                        onIphone -> Toggle(stringResource(R.string.incall_take_here), false, actions.toPhone, Modifier.fillMaxWidth())
                        iphoneThere -> Toggle(stringResource(R.string.incall_to_iphone), false, actions.toIphone, Modifier.fillMaxWidth())
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(40.dp)) {
                    if (phase == CallPhase.INCOMING) {
                        CallButton(stringResource(R.string.incall_reject), Color(0xFFD32F2F), actions.reject)
                        CallButton(stringResource(R.string.incall_answer), Color(0xFF2E7D32), actions.answer)
                    } else {
                        CallButton(stringResource(R.string.incall_end), Color(0xFFD32F2F), actions.hangup)
                    }
                }
            }
        }
    }
}

/** The keypad of a running call: menus of banks and call centres ask for tones. */
@Composable
private fun DialPad(onDigit: (Char) -> Unit) {
    val rows = listOf("123", "456", "789", "*0#")
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        rows.forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                row.forEach { digit ->
                    FilledTonalButton(
                        onClick = { onDigit(digit) },
                        modifier = Modifier.weight(1f).height(56.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFF1B2D36), contentColor = Color.White),
                    ) { Text(digit.toString(), fontSize = 24.sp) }
                }
            }
        }
    }
}

@Composable
private fun Toggle(label: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier.height(56.dp),
        shape = RoundedCornerShape(16.dp),
        colors = if (on) {
            ButtonDefaults.filledTonalButtonColors(containerColor = Color.White, contentColor = Color.Black)
        } else {
            ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFF1B2D36), contentColor = Color.White)
        },
    ) { Text(label, fontSize = 16.sp) }
}

@Composable
private fun CallButton(label: String, color: Color, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        shape = CircleShape,
        colors = ButtonDefaults.buttonColors(containerColor = color, contentColor = Color.White),
        modifier = Modifier.size(width = 130.dp, height = 64.dp),
    ) { Text(label, fontSize = 16.sp) }
}
