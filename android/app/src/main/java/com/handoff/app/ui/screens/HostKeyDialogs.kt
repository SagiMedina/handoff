package com.handoff.app.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.handoff.app.data.HostKeyMismatchException
import com.handoff.app.data.PendingTrustRequest

@Composable
fun HostKeyTrustDialog(
    request: PendingTrustRequest,
    onTrust: () -> Unit,
    onReject: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onReject,
        title = { Text("Verify Mac SSH Key") },
        text = {
            Column {
                Text(
                    "Confirm this fingerprint matches your Mac before trusting it.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(modifier = Modifier.height(16.dp))
                Text("Host", style = MaterialTheme.typography.labelMedium)
                Text(
                    request.host,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text("Algorithm", style = MaterialTheme.typography.labelMedium)
                Text(
                    request.type,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text("Fingerprint", style = MaterialTheme.typography.labelMedium)
                Text(
                    request.fingerprint,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onTrust) {
                Text("Trust")
            }
        },
        dismissButton = {
            TextButton(onClick = onReject) {
                Text("Cancel")
            }
        },
    )
}

@Composable
fun HostKeyMismatchDialog(
    error: HostKeyMismatchException,
    onResetTrust: () -> Unit,
    onCancel: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Mac SSH Key Changed") },
        text = {
            Column {
                Text(
                    "The SSH fingerprint for this Mac no longer matches the trusted key.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(modifier = Modifier.height(16.dp))
                Text("Host", style = MaterialTheme.typography.labelMedium)
                Text(
                    error.host,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text("Trusted", style = MaterialTheme.typography.labelMedium)
                Text(
                    error.expectedFingerprint,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
                Spacer(modifier = Modifier.height(12.dp))
                Text("Presented", style = MaterialTheme.typography.labelMedium)
                Text(
                    error.actualFingerprint,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = FontFamily.Monospace,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onResetTrust) {
                Text("Reset trusted key")
            }
        },
        dismissButton = {
            TextButton(onClick = onCancel) {
                Text("Cancel")
            }
        },
    )
}
