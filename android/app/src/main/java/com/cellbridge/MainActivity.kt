package com.cellbridge

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.produceState
import com.cellbridge.status.HostStatus
import com.cellbridge.server.CONTROL_PORT
import com.cellbridge.status.HostStatusReader
import com.cellbridge.status.pairingLink
import com.cellbridge.ui.MainScreen
import kotlinx.coroutines.delay
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.cellbridge.server.ControlServer
import com.cellbridge.server.ControlService
import com.cellbridge.server.PairingToken
import com.cellbridge.sms.SMS_PERMISSIONS
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var statusReader: HostStatusReader
    @Inject lateinit var deviceId: com.cellbridge.discovery.DeviceId
    @Inject lateinit var pairingToken: PairingToken
    @Inject lateinit var controlServer: ControlServer
    @Inject lateinit var autoHotspot: com.cellbridge.hotspot.AutoHotspot

    /** Bumped on resume and after a role dialog so the role rows re-read the platform state. */
    private var refresh by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The service runs either way; without the permission only its notification stays hidden.
        val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        // This app does not hold the dialer role, so nothing grants it for us: ask, so missed calls can reach the iPhone.
        val callLog = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
        if (checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) callLog.launch(Manifest.permission.READ_CALL_LOG)
        ControlService.start(this)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                val status by produceState<HostStatus?>(null) {
                    while (true) {
                        value = statusReader.read()
                        delay(2_000)
                    }
                }
                val link = pairingLink(pairingToken.value, deviceId.value, status?.addresses?.firstOrNull()?.address, CONTROL_PORT)
                val autoHotspotOn by autoHotspot.enabledFlow.collectAsState()
                MainScreen(status, pairingToken.value, link, ::askToStayAwake, autoHotspotOn, autoHotspot::switchAuto) {
                    SmsAccessRow()
                }
            }
        }
    }

    /** The system's own dialog for leaving the app out of battery optimisation. */
    @android.annotation.SuppressLint("BatteryLife")
    private fun askToStayAwake() {
        runCatching {
            startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:$packageName")))
        }
    }

    override fun onResume() {
        super.onResume()
        refresh++
    }

    @Composable
    private fun SmsAccessRow() {
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
        val granted = refresh.let { SMS_PERMISSIONS.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } } // re-read whenever [refresh] changes
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text(stringResource(R.string.role_sms))
                Text(stringResource(if (granted) R.string.role_granted else R.string.role_missing), style = MaterialTheme.typography.bodySmall)
            }
            if (!granted) {
                Button(onClick = { launcher.launch(SMS_PERMISSIONS) }) { Text(stringResource(R.string.role_request)) }
            }
        }
    }
}
