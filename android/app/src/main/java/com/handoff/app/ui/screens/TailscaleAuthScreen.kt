package com.handoff.app.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.handoff.app.data.friendlyTailscaleError
import com.handoff.app.data.TailscaleManager
import com.handoff.app.data.TailscaleState
import com.handoff.app.ui.theme.HandoffGreen
import kotlinx.coroutines.launch

@Composable
fun TailscaleAuthScreen(
    tailscaleManager: TailscaleManager,
    onAuthenticated: () -> Unit,
    onError: (String) -> Unit
) {
    val state by tailscaleManager.state.collectAsState()
    val authUrl by tailscaleManager.authUrl.collectAsState()
    val tsError by tailscaleManager.error.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        try {
            tailscaleManager.start()
            onAuthenticated()
        } catch (e: Exception) {
            // Error state handled by UI below
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        when (state) {
            TailscaleState.STARTING, TailscaleState.STOPPED -> {
                CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                Spacer(modifier = Modifier.height(24.dp))
                Text(
                    text = "Connecting to Tailscale...",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            TailscaleState.NEEDS_AUTH -> {
                Text(
                    text = "Sign in to Tailscale",
                    style = MaterialTheme.typography.titleLarge,
                    fontSize = 24.sp,
                    color = MaterialTheme.colorScheme.onBackground
                )

                Spacer(modifier = Modifier.height(12.dp))

                Text(
                    text = "One-time setup: sign in to connect\nthis device to your tailnet.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    lineHeight = 24.sp
                )

                Spacer(modifier = Modifier.height(32.dp))

                val url = authUrl
                if (url != null) {
                    Button(
                        onClick = {
                            context.startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            )
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(56.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary
                        )
                    ) {
                        Text("Open Browser to Sign In", fontSize = 16.sp)
                    }

                    Spacer(modifier = Modifier.height(16.dp))

                    Text(
                        text = "Waiting for authentication...",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )

                    Spacer(modifier = Modifier.height(8.dp))

                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
            }

            TailscaleState.CONNECTED -> {
                Text("●", color = HandoffGreen, fontSize = 32.sp)
                Spacer(modifier = Modifier.height(12.dp))
                Text(
                    text = "Connected",
                    style = MaterialTheme.typography.titleMedium,
                    color = HandoffGreen
                )
            }

            TailscaleState.ERROR -> {
                Text(
                    text = friendlyTailscaleError(tsError),
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center
                )

                Spacer(modifier = Modifier.height(16.dp))

                Button(onClick = {
                    scope.launch {
                        try {
                            tailscaleManager.start()
                            onAuthenticated()
                        } catch (_: Exception) {}
                    }
                }) {
                    Text("Retry")
                }

                Spacer(modifier = Modifier.height(8.dp))

                TextButton(onClick = {
                    tailscaleManager.resetState()
                    scope.launch {
                        try {
                            tailscaleManager.start()
                            onAuthenticated()
                        } catch (_: Exception) {}
                    }
                }) {
                    Text("Reset & Retry")
                }
            }
        }
    }
}
