package com.handoff.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.GateException
import com.handoff.app.data.friendlyActionError
import com.handoff.app.data.friendlyConnectionError
import com.handoff.app.data.friendlyGateError
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.data.TmuxSession
import com.handoff.app.data.TmuxWindow
import com.handoff.app.ui.components.SessionCard
import com.handoff.app.ui.theme.HandoffAmber
import com.handoff.app.ui.theme.HandoffAmberDim
import com.handoff.app.ui.theme.HandoffGreen
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun SessionsScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    tailscaleManager: TailscaleManager,
    onWindowSelected: (String, TmuxWindow) -> Unit,
    onUnpair: () -> Unit,
    onLicenses: () -> Unit = {},
    onSettings: () -> Unit = {}
) {
    var sessions by remember { mutableStateOf<List<TmuxSession>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var showNewSessionDialog by remember { mutableStateOf(false) }
    var newSessionName by remember { mutableStateOf("") }
    var showIp by remember { mutableStateOf(false) }
    var readOnly by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun refresh(showLoading: Boolean = true) {
        scope.launch {
            if (showLoading) loading = true
            error = null
            try {
                if (!sshManager.isConnected) {
                    val proxyPort = tailscaleManager.startProxy(config.ip)
                    sshManager.connect(config, proxyPort)
                }
                val rawSessions = sshManager.listSessions(config.tmuxPath)

                // Update read-only state from gate permissions
                sshManager.devicePermissions?.let { perms ->
                    readOnly = perms.readOnly
                }

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
            } catch (e: GateException) {
                error = friendlyGateError(e.gateError)
                sshManager.disconnect()
            } catch (e: Exception) {
                error = friendlyConnectionError(e)
                sshManager.disconnect()
            } finally {
                if (showLoading) loading = false
            }
        }
    }

    LaunchedEffect(Unit) {
        refresh()
        // Auto-refresh every 5 seconds while screen is visible
        while (true) {
            delay(5000)
            if (!loading) refresh(showLoading = false)
        }
    }

    if (showNewSessionDialog) {
        AlertDialog(
            onDismissRequest = { showNewSessionDialog = false },
            title = { Text("New Session") },
            text = {
                OutlinedTextField(
                    value = newSessionName,
                    onValueChange = { newSessionName = it },
                    label = { Text("Session name") },
                    singleLine = true
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val name = newSessionName.trim()
                        if (name.isNotEmpty()) {
                            showNewSessionDialog = false
                            scope.launch {
                                try {
                                    sshManager.createSession(config.tmuxPath, name)
                                    refresh()
                                } catch (e: Exception) {
                                    error = friendlyActionError("create session", e)
                                }
                            }
                        }
                    }
                ) { Text("Create") }
            },
            dismissButton = {
                TextButton(onClick = { showNewSessionDialog = false }) { Text("Cancel") }
            }
        )
    }

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
                if (showIp) {
                    Text(
                        text = config.ip,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.clickable { showIp = false }
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { refresh() }) {
                    Text("Refresh")
                }
                TextButton(onClick = onSettings) {
                    Text("Settings")
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
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.padding(horizontal = 32.dp)
                    ) {
                        Text(
                            text = error!!,
                            color = MaterialTheme.colorScheme.error,
                            textAlign = TextAlign.Center,
                            style = MaterialTheme.typography.bodyLarge
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
                            text = if (readOnly) "No sessions available in read-only mode"
                                else "Create a session or open a terminal on your Mac",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (!readOnly) {
                            Spacer(modifier = Modifier.height(16.dp))
                            Button(onClick = {
                                newSessionName = "main"
                                showNewSessionDialog = true
                            }) {
                                Text("New Session")
                            }
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        TextButton(onClick = { refresh() }) {
                            Text("Refresh")
                        }
                    }
                }
            }
            else -> {
                // Connected indicator — tap to show/hide IP
                Row(
                    modifier = Modifier.clickable { showIp = !showIp },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    val statusColor = if (readOnly) HandoffAmber else HandoffGreen
                    Text("●", color = statusColor, style = MaterialTheme.typography.labelSmall)
                    Text(
                        text = if (showIp) "Connected — ${config.ip}" else "Connected",
                        color = statusColor,
                        style = MaterialTheme.typography.labelMedium
                    )
                    if (readOnly) {
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = "READ-ONLY",
                            color = HandoffAmber,
                            style = MaterialTheme.typography.labelMedium.copy(
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 1.sp
                            ),
                            modifier = Modifier
                                .background(
                                    color = HandoffAmberDim,
                                    shape = RoundedCornerShape(4.dp)
                                )
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        )
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))

                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(sessions, key = { it.name }) { session ->
                        SessionCard(
                            session = session,
                            readOnly = readOnly,
                            onWindowClick = { window ->
                                onWindowSelected(session.name, window)
                            },
                            onNewWindow = if (readOnly) null else ({
                                scope.launch {
                                    try {
                                        val windowIndex = sshManager.createWindow(config.tmuxPath, session.name)
                                        val newWindow = TmuxWindow(index = windowIndex, title = "shell", command = "")
                                        onWindowSelected(session.name, newWindow)
                                    } catch (e: Exception) {
                                        error = friendlyActionError("create tab", e)
                                    }
                                }
                            }),
                            onKillSession = if (readOnly) null else ({
                                scope.launch {
                                    try {
                                        sshManager.killSession(config.tmuxPath, session.name)
                                        refresh()
                                    } catch (e: Exception) {
                                        error = friendlyActionError("close session", e)
                                    }
                                }
                            }),
                            onKillWindow = if (readOnly) null else ({ window ->
                                scope.launch {
                                    try {
                                        sshManager.killWindow(config.tmuxPath, session.name, window.index)
                                        refresh()
                                    } catch (e: Exception) {
                                        error = friendlyActionError("close tab", e)
                                    }
                                }
                            })
                        )
                    }
                    if (!readOnly) {
                        item {
                            TextButton(
                                onClick = {
                                    newSessionName = ""
                                    showNewSessionDialog = true
                                },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(
                                    text = "+ new session",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                    style = MaterialTheme.typography.labelMedium
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
