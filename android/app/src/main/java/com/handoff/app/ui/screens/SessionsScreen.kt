package com.handoff.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.SshManager
import com.handoff.app.data.TmuxSession
import com.handoff.app.data.TmuxWindow
import com.handoff.app.ui.components.SessionCard
import com.handoff.app.ui.theme.HandoffGreen
import kotlinx.coroutines.launch

@Composable
fun SessionsScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    onWindowSelected: (String, TmuxWindow) -> Unit,
    onUnpair: () -> Unit
) {
    var sessions by remember { mutableStateOf<List<TmuxSession>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun refresh() {
        scope.launch {
            loading = true
            error = null
            try {
                if (!sshManager.isConnected) {
                    sshManager.connect(config)
                }
                val rawSessions = sshManager.listSessions(config.tmuxPath)

                // Load windows for each session
                val sessionsWithWindows = rawSessions.map { session ->
                    val windows = sshManager.listWindows(config.tmuxPath, session.name)
                    session.copy(windows = windows)
                }
                sessions = sessionsWithWindows

                // Auto-connect: single session with single window
                if (sessionsWithWindows.size == 1 && sessionsWithWindows[0].windows.size == 1) {
                    val s = sessionsWithWindows[0]
                    onWindowSelected(s.name, s.windows[0])
                    return@launch
                }
            } catch (e: Exception) {
                error = "Connection failed: ${e.message}"
            } finally {
                loading = false
            }
        }
    }

    LaunchedEffect(Unit) { refresh() }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = "Handoff",
                    style = MaterialTheme.typography.titleLarge
                )
                Text(
                    text = config.ip,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = { refresh() }) {
                    Text("Refresh")
                }
                TextButton(onClick = onUnpair) {
                    Text("Unpair", color = MaterialTheme.colorScheme.error)
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        when {
            loading -> {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(
                            color = MaterialTheme.colorScheme.primary
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "Connecting to Mac...",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
            error != null -> {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = error!!,
                            color = MaterialTheme.colorScheme.error
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Button(onClick = { refresh() }) {
                            Text("Retry")
                        }
                    }
                }
            }
            sessions.isEmpty() -> {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = "No active sessions",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Open a terminal on your Mac to get started",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Button(onClick = { refresh() }) {
                            Text("Refresh")
                        }
                    }
                }
            }
            else -> {
                // Connected indicator
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text("●", color = HandoffGreen, style = MaterialTheme.typography.labelSmall)
                    Text(
                        text = "Connected",
                        color = HandoffGreen,
                        style = MaterialTheme.typography.labelMedium
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(sessions, key = { it.name }) { session ->
                        SessionCard(
                            session = session,
                            onWindowClick = { window ->
                                onWindowSelected(session.name, window)
                            }
                        )
                    }
                }
            }
        }
    }
}
