package com.handoff.app.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.*
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.handoff.app.data.ConfigStore
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
import android.util.Log
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionsScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    tailscaleManager: TailscaleManager,
    cachedSessions: MutableState<List<TmuxSession>>,
    onWindowSelected: (String, TmuxWindow) -> Unit,
    onUnpair: () -> Unit,
    onLicenses: () -> Unit = {},
    onSettings: () -> Unit = {}
) {
    // Sessions are cached at the activity level so returning from the terminal screen
    // shows the previous list immediately and the loading spinner only appears on a
    // genuine first-time load.
    var sessions by cachedSessions
    var loading by remember { mutableStateOf(sessions.isEmpty()) }
    var error by remember { mutableStateOf<String?>(null) }
    var showNewSessionDialog by remember { mutableStateOf(false) }
    var newSessionName by remember { mutableStateOf("") }
    var showIp by remember { mutableStateOf(false) }
    var readOnly by remember { mutableStateOf(false) }
    var filter by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val configStore = remember { ConfigStore(context.applicationContext) }
    val pinnedWindows by configStore.pinnedWindows.collectAsState(initial = emptySet())

    fun copyToClipboard(label: String, value: String) {
        val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clip.setPrimaryClip(ClipData.newPlainText(label, value))
        // Android 13+ shows its own clipboard toast; older versions need ours.
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU) {
            Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
        }
    }

    fun refresh(showLoading: Boolean = true, forceReconnect: Boolean = false) {
        scope.launch {
            if (showLoading) loading = true
            error = null
            try {
                if (forceReconnect) {
                    // Force clean state — stale connections won't recover otherwise
                    sshManager.disconnect()
                    tailscaleManager.stopProxy()
                }
                if (!sshManager.isConnected) {
                    try {
                        val proxyPort = tailscaleManager.startProxy(config.ip)
                        sshManager.connect(config, proxyPort)
                    } catch (e: Exception) {
                        // Tailscale tunnel may be stale after backgrounding — restart it
                        Log.d("Handoff", "Reconnect failed, restarting Tailscale: ${e.message}")
                        sshManager.disconnect()
                        tailscaleManager.stop()
                        withTimeout(15_000) { tailscaleManager.start() }
                        val proxyPort = tailscaleManager.startProxy(config.ip)
                        sshManager.connect(config, proxyPort)
                    }
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
                tailscaleManager.stopProxy()
            } catch (e: Exception) {
                error = friendlyConnectionError(e)
                sshManager.disconnect()
                tailscaleManager.stopProxy()
            } finally {
                if (showLoading) loading = false
            }
        }
    }

    LaunchedEffect(Unit) {
        // Re-entering the screen with cached data: refresh silently in the background
        // so the list stays responsive without a spinner flash.
        refresh(showLoading = sessions.isEmpty())
        // Auto-refresh every 5 seconds while screen is visible and connected
        while (true) {
            delay(5000)
            if (!loading && error == null) refresh(showLoading = false)
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

    var menuExpanded by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val totalWindows = sessions.sumOf { it.windows.size }
    val matchCount = remember(sessions, filter) {
        if (filter.isBlank()) totalWindows
        else sessions.sumOf { s ->
            s.windows.count { w ->
                w.title.contains(filter, ignoreCase = true) ||
                    w.cwd.contains(filter, ignoreCase = true)
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Main content area — flexible, takes all space above the footer status bar.
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 16.dp)
                .padding(top = 12.dp),
        ) {
            // Header — restrained. Brand lowercase because this is a terminal tool, not
            // a consumer app shouting its name. Settings + Unpair hide in the overflow
            // menu so Unpair's destructive-red doesn't dominate the top bar on every
            // visit. Only the most-used action (refresh) stays as a primary control.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "handoff",
                    style = MaterialTheme.typography.titleLarge,
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { refresh(forceReconnect = true) }) {
                        Text("\u21BB", fontSize = 20.sp, fontFamily = FontFamily.Monospace)
                    }
                    Box {
                        IconButton(onClick = { menuExpanded = true }) {
                            Text("\u22EF", fontSize = 22.sp, fontFamily = FontFamily.Monospace)
                        }
                        DropdownMenu(
                            expanded = menuExpanded,
                            onDismissRequest = { menuExpanded = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Settings") },
                                onClick = {
                                    menuExpanded = false
                                    onSettings()
                                },
                            )
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        "Unpair",
                                        color = MaterialTheme.colorScheme.error,
                                    )
                                },
                                onClick = {
                                    menuExpanded = false
                                    onUnpair()
                                },
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(4.dp))

            // Filter row — inline, single-line, prompt-style. Appears only when there are
            // enough tabs to justify it. No Material field border: a thin underline is all
            // the affordance a terminal-aesthetic app needs, and it reclaims ~40dp of
            // vertical real estate on small screens.
            if (totalWindows >= 6) {
                FilterRow(
                    value = filter,
                    onValueChange = { filter = it },
                    matchCount = matchCount,
                    total = totalWindows,
                    onClear = {
                        filter = ""
                        focusManager.clearFocus()
                    },
                )
            }

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
                        Button(onClick = { refresh(forceReconnect = true) }) {
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
                // The old "Connected" indicator has moved to the footer status bar at the
                // bottom of the screen — free vertical real estate here for the tab list,
                // which is what users actually came to see.
                Spacer(modifier = Modifier.height(8.dp))

                // Filter tabs by title/cwd substring, then reorder so pinned tabs float to
                // the top of each session. Drop sessions whose tabs all got filtered out.
                val visibleSessions = remember(sessions, filter, pinnedWindows) {
                    sessions.mapNotNull { s ->
                        val matches = if (filter.isBlank()) s.windows else s.windows.filter { w ->
                            w.title.contains(filter, ignoreCase = true) ||
                                w.cwd.contains(filter, ignoreCase = true)
                        }
                        if (matches.isEmpty()) return@mapNotNull null
                        val sorted = matches.sortedByDescending { w ->
                            "${s.name}${ConfigStore.PIN_SEP}${w.title}" in pinnedWindows
                        }
                        s.copy(windows = sorted)
                    }
                }

                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(visibleSessions, key = { it.name }) { session ->
                        SessionCard(
                            session = session,
                            readOnly = readOnly,
                            isWindowPinned = { w ->
                                "${session.name}${ConfigStore.PIN_SEP}${w.title}" in pinnedWindows
                            },
                            onToggleWindowPin = { w ->
                                scope.launch {
                                    configStore.togglePinnedWindow(session.name, w.title)
                                }
                            },
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
                            // Plain low-emphasis text link — matches the "+ new tab"
                            // styling inside each session for consistent visual rhythm.
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        newSessionName = ""
                                        showNewSessionDialog = true
                                    }
                                    .padding(vertical = 14.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = "+ ",
                                        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.7f),
                                        style = MaterialTheme.typography.labelMedium,
                                    )
                                    Text(
                                        text = "new session",
                                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                        style = MaterialTheme.typography.labelMedium,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        }  // end main content Column

        // ── Footer status bar ──────────────────────────────────────────────────
        // Persistent tmux-style status line: connection dot, IP, tab count.
        // Replaces the old floating "Connected" row + hidden "tap Handoff to reveal IP"
        // toggle with a single always-visible, always-readable line. Tap the IP segment
        // to copy it; tap the tab count to jump to the filter.
        StatusBar(
            ip = config.ip,
            totalWindows = totalWindows,
            readOnly = readOnly,
            onCopyIp = { copyToClipboard("Tailscale IP", config.ip) },
        )
    }
}

@Composable
private fun FilterRow(
    value: String,
    onValueChange: (String) -> Unit,
    matchCount: Int,
    total: Int,
    onClear: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp, bottom = 10.dp)
            .drawBehind {
                // 1dp underline that spans the whole row. Always visible, low contrast;
                // lights up brighter when the field is focused (handled below via the
                // focus color on the text itself).
                val y = size.height - 0.5.dp.toPx()
                drawLine(
                    color = Color.White.copy(alpha = 0.08f),
                    start = Offset(0f, y),
                    end = Offset(size.width, y),
                    strokeWidth = 1.dp.toPx(),
                )
            }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "/",
            style = MaterialTheme.typography.bodyLarge,
            color = scheme.primary.copy(alpha = 0.7f),
            modifier = Modifier.padding(end = 10.dp),
        )
        Box(modifier = Modifier.weight(1f)) {
            if (value.isEmpty()) {
                Text(
                    text = "filter tabs by name or path",
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurfaceVariant.copy(alpha = 0.5f),
                )
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                cursorBrush = SolidColor(scheme.primary),
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = scheme.onBackground),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (value.isNotEmpty()) {
            // Match count — tight monospace, disappears when filter is cleared.
            Text(
                text = "$matchCount/$total",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 10.dp),
            )
            Box(
                modifier = Modifier
                    .clickable(onClick = onClear)
                    .padding(horizontal = 4.dp, vertical = 2.dp),
            ) {
                Text(
                    text = "\u00D7",  // ×
                    fontSize = 18.sp,
                    fontFamily = FontFamily.Monospace,
                    color = scheme.onSurfaceVariant,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun StatusBar(
    ip: String,
    totalWindows: Int,
    readOnly: Boolean,
    onCopyIp: () -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    val statusColor = if (readOnly) HandoffAmber else HandoffGreen
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .drawBehind {
                // Thin top-border separator — gives the status bar its "status line"
                // identity without committing to a hard divider that would fight the
                // minimal aesthetic elsewhere.
                drawLine(
                    color = Color.White.copy(alpha = 0.06f),
                    start = Offset(0f, 0f),
                    end = Offset(size.width, 0f),
                    strokeWidth = 1.dp.toPx(),
                )
            }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "\u25CF",  // ●
            color = statusColor,
            fontSize = 9.sp,
            modifier = Modifier.padding(end = 8.dp),
        )
        Text(
            text = if (readOnly) "read-only" else "connected",
            style = MaterialTheme.typography.bodySmall,
            color = statusColor,
        )
        SeparatorDot()
        // Tap the IP to copy it — one gesture, no visible affordance needed; power users
        // will learn it, casual users don't need it.
        Text(
            text = ip,
            style = MaterialTheme.typography.bodySmall,
            color = scheme.onSurfaceVariant,
            modifier = Modifier
                .combinedClickable(
                    onClick = onCopyIp,
                    onLongClick = onCopyIp,
                )
                .padding(vertical = 2.dp),
        )
        SeparatorDot()
        Text(
            text = "$totalWindows ${if (totalWindows == 1) "tab" else "tabs"}",
            style = MaterialTheme.typography.bodySmall,
            color = scheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SeparatorDot() {
    Text(
        text = " · ",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
    )
}
