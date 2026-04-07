package com.handoff.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.SshManager
import com.handoff.app.ui.components.MobileToolbar
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.InputStream
import java.io.OutputStream

@Composable
fun TerminalScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    sessionName: String,
    windowIndex: Int,
    onDisconnect: () -> Unit
) {
    var connected by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var outputStream by remember { mutableStateOf<OutputStream?>(null) }
    val scope = rememberCoroutineScope()

    // Estimate terminal size
    val configuration = LocalConfiguration.current
    val cols = (configuration.screenWidthDp / 8).coerceIn(40, 200)
    val rows = ((configuration.screenHeightDp - 60) / 16).coerceIn(10, 100)

    LaunchedEffect(Unit) {
        try {
            if (!sshManager.isConnected) {
                sshManager.connect(config)
            }
            val (input, output) = sshManager.openShell(
                config.tmuxPath, sessionName, windowIndex, cols, rows
            )
            outputStream = output
            connected = true
        } catch (e: Exception) {
            error = "Failed to connect: ${e.message}"
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        when {
            error != null -> {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = error!!,
                            color = MaterialTheme.colorScheme.error
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Button(onClick = onDisconnect) {
                            Text("Back")
                        }
                    }
                }
            }
            !connected -> {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(
                            color = MaterialTheme.colorScheme.primary
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "Attaching to $sessionName:$windowIndex...",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            else -> {
                // Terminal view placeholder
                // Note: Full terminal-view integration requires bridging SSH I/O
                // to the Termux TerminalEmulator which needs native JNI setup.
                // This is a simplified version that will be enhanced.
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .weight(1f)
                )

                // Mobile toolbar
                MobileToolbar(
                    onKey = { bytes ->
                        scope.launch(Dispatchers.IO) {
                            try {
                                outputStream?.write(bytes)
                                outputStream?.flush()
                            } catch (e: Exception) {
                                // Connection lost
                            }
                        }
                    }
                )
            }
        }
    }
}
