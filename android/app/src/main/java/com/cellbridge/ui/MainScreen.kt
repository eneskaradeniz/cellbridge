package com.cellbridge.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.cellbridge.status.HostStatus

/**
 * The phone's own app: only how the bridge is doing and how to pair. Calls on this phone belong to the stock Phone app (this
 * app only watches them); texts still use this app's SMS role until they move to the stock Messages app. The iPhone drives the hand-overs.
 */
@Composable
fun MainScreen(
    status: HostStatus?,
    pairingCode: String,
    pairingLink: String,
    onUnrestrict: () -> Unit,
    autoHotspot: Boolean,
    onAutoHotspot: (Boolean) -> Unit,
    roles: @Composable () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            StatusScreen(status, pairingCode, pairingLink, onUnrestrict, autoHotspot, onAutoHotspot, roles)
        }
    }
}
