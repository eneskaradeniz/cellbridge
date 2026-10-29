package com.cellbridge

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
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
import com.cellbridge.telecom.AppRole
import com.cellbridge.telecom.DefaultRoles
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var roles: DefaultRoles
    @Inject lateinit var pairingToken: PairingToken
    @Inject lateinit var controlServer: ControlServer

    /** Bumped on resume and after a role dialog so the role rows re-read the platform state. */
    private var refresh by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The service runs either way; without the permission only its notification stays hidden.
        val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        // The dialer role normally brings this along; ask in case it did not, so missed calls can reach the iPhone.
        val callLog = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
        if (checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) callLog.launch(Manifest.permission.READ_CALL_LOG)
        ControlService.start(this)
        setContent {
            MaterialTheme {
                Column(
                    modifier = Modifier.safeDrawingPadding().padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium)
                    RoleRow(AppRole.DIALER, R.string.role_dialer)
                    RoleRow(AppRole.SMS, R.string.role_sms)
                    val running by controlServer.running.collectAsState()
                    Text(stringResource(if (running) R.string.server_running else R.string.server_stopped))
                    Text(stringResource(R.string.pairing_token), style = MaterialTheme.typography.bodySmall)
                    SelectionContainer { Text(pairingToken.value, style = MaterialTheme.typography.headlineSmall) }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refresh++
    }

    @Composable
    private fun RoleRow(role: AppRole, label: Int) {
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { refresh++ }
        val state = refresh.let { // re-evaluated whenever [refresh] changes
            when {
                !roles.isAvailable(role) -> R.string.role_unavailable
                roles.isHeld(role) -> R.string.role_granted
                else -> R.string.role_missing
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column {
                Text(stringResource(label))
                Text(stringResource(state), style = MaterialTheme.typography.bodySmall)
            }
            if (state == R.string.role_missing) {
                Button(onClick = { launcher.launch(roles.requestIntent(role)) }) {
                    Text(stringResource(R.string.role_request))
                }
            }
        }
    }
}
