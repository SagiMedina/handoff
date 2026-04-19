package com.handoff.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.util.Log
import com.handoff.app.BuildConfig
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.GateException
import com.handoff.app.data.HostKeyMismatchException
import com.handoff.app.data.HostKeyUnknownException
import com.handoff.app.data.PendingTrustRequest
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.data.friendlyConnectionError
import com.handoff.app.data.friendlyGateError
import kotlinx.coroutines.delay

@Composable
fun VerificationScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    tailscaleManager: TailscaleManager,
    onVerified: () -> Unit,
    onError: (String) -> Unit
) {
    var verificationCode by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf("Connecting to Mac...") }
    var connecting by remember { mutableStateOf(true) }
    var pendingTrust by remember { mutableStateOf<PendingTrustRequest?>(null) }
    var hostKeyMismatch by remember { mutableStateOf<HostKeyMismatchException?>(null) }
    var retryToken by remember { mutableIntStateOf(0) }

    pendingTrust?.let { request ->
        HostKeyTrustDialog(
            request = request,
            onTrust = {
                sshManager.approveTrust(request)
                pendingTrust = null
                connecting = true
                retryToken++
            },
            onReject = {
                pendingTrust = null
                onError("SSH key trust was cancelled.")
            }
        )
    }

    hostKeyMismatch?.let { mismatch ->
        HostKeyMismatchDialog(
            error = mismatch,
            onResetTrust = {
                sshManager.resetTrust(mismatch.host)
                hostKeyMismatch = null
                connecting = true
                retryToken++
            },
            onCancel = {
                hostKeyMismatch = null
                onError("SSH key verification was cancelled.")
            }
        )
    }

    LaunchedEffect(retryToken) {
        try {
            connecting = true
            verificationCode = null
            // Connect via Tailscale + SSH
            status = "Starting secure connection..."
            if (BuildConfig.DEBUG) Log.d("Handoff", "VerificationScreen: starting proxy")
            val proxyPort = tailscaleManager.startProxy(config.ip)
            if (BuildConfig.DEBUG) Log.d("Handoff", "VerificationScreen: connecting SSH")
            sshManager.connect(config, proxyPort)

            // List-first: if device is already active, skip pairing entirely.
            // Gate returns "error:pending" for pending devices, allowing through otherwise.
            status = "Verifying with Mac..."
            try {
                sshManager.listSessions(config.tmuxPath)
                if (BuildConfig.DEBUG) Log.d("Handoff", "VerificationScreen: device already active")
                onVerified()
                return@LaunchedEffect
            } catch (e: GateException) {
                if (e.gateError != "error:pending") throw e
                // Pending — fall through to pair flow
            }

            // Send pair command to gate (only for pending devices)
            if (BuildConfig.DEBUG) Log.d("Handoff", "VerificationScreen: sending pair command")
            val response = sshManager.sendPairCommand()
            if (BuildConfig.DEBUG) Log.d("Handoff", "VerificationScreen: pair response=$response")

            if (response.startsWith("verify:")) {
                val code = response.removePrefix("verify:")
                verificationCode = code
                connecting = false
                status = "Confirm this code on your Mac"

                // Poll: wait for Mac to confirm (device becomes active)
                // The gate will accept "list" once status is active
                var attempts = 0
                while (attempts < 30) {  // 60 seconds max
                    delay(2000)
                    attempts++
                    try {
                        sshManager.disconnect()
                        val newPort = tailscaleManager.startProxy(config.ip)
                        sshManager.connect(config, newPort)
                        sshManager.listSessions(config.tmuxPath)
                        // If list succeeds, device is active
                        onVerified()
                        return@LaunchedEffect
                    } catch (e: GateException) {
                        if (e.gateError == "error:pending") {
                            // Still pending, keep waiting
                            continue
                        } else if (e.gateError == "error:not_found") {
                            // Pairing was rejected or timed out
                            onError("Pairing was rejected on the Mac.")
                            return@LaunchedEffect
                        }
                    } catch (e: Exception) {
                        // If SSH auth failed, the Mac deleted the device — either the
                        // user rejected this pairing or an admin revoked it. Don't keep
                        // polling for a minute; tell the user to re-pair and bail.
                        val m = (e.message ?: "").lowercase()
                        if ("auth fail" in m || "auth cancel" in m || "publickey" in m) {
                            onError(
                                "Pairing was rejected. Run `handoff pair` on your Mac again."
                            )
                            return@LaunchedEffect
                        }
                        // Otherwise assume a transient connection error and retry.
                    }
                }
                onError("Pairing timed out. Try again from your Mac.")
            } else {
                onError("Unexpected response from Mac.")
            }
        } catch (e: GateException) {
            if (BuildConfig.DEBUG) Log.e("Handoff", "VerificationScreen: gate error=${e.gateError}")
            onError(friendlyGateError(e.gateError))
        } catch (e: HostKeyUnknownException) {
            connecting = false
            tailscaleManager.stopProxy()
            pendingTrust = e.request
        } catch (e: HostKeyMismatchException) {
            connecting = false
            tailscaleManager.stopProxy()
            hostKeyMismatch = e
        } catch (e: Exception) {
            if (BuildConfig.DEBUG) Log.e("Handoff", "VerificationScreen: error", e)
            onError(friendlyConnectionError(e))
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "Pairing",
            style = MaterialTheme.typography.headlineMedium
        )

        Spacer(modifier = Modifier.height(32.dp))

        if (connecting) {
            CircularProgressIndicator(
                color = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = status,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        } else if (verificationCode != null) {
            Text(
                text = "Verification Code",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Display code as "123 456"
            val code = verificationCode!!
            val formatted = "${code.take(3)} ${code.drop(3)}"
            Text(
                text = formatted,
                fontFamily = FontFamily.Monospace,
                fontSize = 48.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 8.sp,
                color = MaterialTheme.colorScheme.primary
            )

            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = status,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "Waiting for confirmation...",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
            )

            Spacer(modifier = Modifier.height(16.dp))

            CircularProgressIndicator(
                modifier = Modifier.size(24.dp),
                strokeWidth = 2.dp,
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f)
            )
        }
    }
}
