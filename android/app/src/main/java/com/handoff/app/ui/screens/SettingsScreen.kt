package com.handoff.app.ui.screens

import androidx.biometric.BiometricManager
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import android.util.Log
import androidx.compose.ui.unit.dp
import com.handoff.app.BuildConfig
import com.handoff.app.data.BiometricKeyStore
import com.handoff.app.data.ConfigStore
import com.handoff.app.data.ConnectionConfig
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    config: ConnectionConfig,
    biometricKeyStore: BiometricKeyStore,
    onBack: () -> Unit,
    onLicenses: () -> Unit = {}
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val configStore = remember { ConfigStore(context.applicationContext) }
    val fontSize by configStore.terminalFontSize
        .collectAsState(initial = ConfigStore.DEFAULT_TERMINAL_FONT_SIZE)
    var biometricEnabled by remember { mutableStateOf(biometricKeyStore.isBiometricEnabled) }
    var biometricAvailable by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val canAuth = BiometricManager.from(context)
            .canAuthenticate(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
        biometricAvailable = canAuth == BiometricManager.BIOMETRIC_SUCCESS
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Settings",
                style = MaterialTheme.typography.titleLarge
            )
            TextButton(onClick = onBack) {
                Text("Done")
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Security section
        Text(
            text = "Security",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.primary
        )

        Spacer(modifier = Modifier.height(12.dp))

        if (biometricAvailable) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Require unlock to open app",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Text(
                        text = "Use fingerprint, face, or PIN to access Handoff",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = biometricEnabled,
                    onCheckedChange = { enabled ->
                        try {
                            biometricKeyStore.saveKey(config.privateKey, enabled)
                            biometricEnabled = enabled
                        } catch (e: Exception) {
                            // Keystore encryption failed — don't toggle
                            if (BuildConfig.DEBUG) Log.e("Handoff", "BiometricKeyStore.saveKey failed", e)
                        }
                    }
                )
            }
        } else {
            Text(
                text = "Biometric authentication is not available on this device.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Spacer(modifier = Modifier.height(32.dp))

        // Terminal appearance
        Text(
            text = "Terminal",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.primary,
        )
        Spacer(modifier = Modifier.height(12.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = "Text size",
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                text = "${fontSize}px",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Slider(
            value = fontSize.toFloat(),
            onValueChange = { v ->
                scope.launch { configStore.setTerminalFontSize(v.toInt()) }
            },
            valueRange = ConfigStore.MIN_TERMINAL_FONT_SIZE.toFloat()..
                ConfigStore.MAX_TERMINAL_FONT_SIZE.toFloat(),
            steps = ConfigStore.MAX_TERMINAL_FONT_SIZE - ConfigStore.MIN_TERMINAL_FONT_SIZE - 1,
        )

        Spacer(modifier = Modifier.height(32.dp))

        // Device info section
        Text(
            text = "Device",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.primary
        )

        Spacer(modifier = Modifier.height(12.dp))

        SettingsRow("Protocol version", "v${config.protocolVersion}")
        if (config.deviceName.isNotBlank()) {
            SettingsRow("Device name", config.deviceName)
        }
        SettingsRow("Mac IP", config.ip)
        SettingsRow("Mac user", config.user)

        Spacer(modifier = Modifier.weight(1f))

        TextButton(
            onClick = onLicenses,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "Open Source Licenses",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun SettingsRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium
        )
    }
}
