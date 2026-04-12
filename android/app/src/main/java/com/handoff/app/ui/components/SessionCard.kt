package com.handoff.app.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.handoff.app.data.TmuxSession
import com.handoff.app.data.TmuxWindow
import com.handoff.app.ui.theme.HandoffGreen

@Composable
fun SessionCard(
    session: TmuxSession,
    onWindowClick: (TmuxWindow) -> Unit,
    onNewWindow: () -> Unit,
    onKillSession: () -> Unit,
    onKillWindow: (TmuxWindow) -> Unit,
    modifier: Modifier = Modifier
) {
    var showKillSessionDialog by remember { mutableStateOf(false) }
    var windowToKill by remember { mutableStateOf<TmuxWindow?>(null) }

    if (showKillSessionDialog) {
        AlertDialog(
            onDismissRequest = { showKillSessionDialog = false },
            title = { Text("Kill session?") },
            text = { Text("This will close all ${session.windowCount} windows in \"${session.name}\".") },
            confirmButton = {
                TextButton(onClick = {
                    showKillSessionDialog = false
                    onKillSession()
                }) { Text("Kill", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showKillSessionDialog = false }) { Text("Cancel") }
            }
        )
    }

    windowToKill?.let { window ->
        AlertDialog(
            onDismissRequest = { windowToKill = null },
            title = { Text("Kill window?") },
            text = { Text("Close \"${window.title}\" in session \"${session.name}\"?") },
            confirmButton = {
                TextButton(onClick = {
                    windowToKill = null
                    onKillWindow(window)
                }) { Text("Kill", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { windowToKill = null }) { Text("Cancel") }
            }
        )
    }

    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        )
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = "●",
                        color = HandoffGreen,
                        fontSize = 10.sp
                    )
                    Text(
                        text = session.name,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "${session.windowCount} ${if (session.windowCount == 1) "window" else "windows"}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    text = "Kill",
                    modifier = Modifier
                        .clickable { showKillSessionDialog = true }
                        .padding(4.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error
                )
            }

            Spacer(modifier = Modifier.height(8.dp))
            if (session.windows.isNotEmpty()) {
                session.windows.forEach { window ->
                    WindowRow(
                        window = window,
                        onClick = { onWindowClick(window) },
                        onLongClick = { windowToKill = window }
                    )
                }
            }
            Spacer(modifier = Modifier.height(4.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onNewWindow)
                    .padding(vertical = 10.dp, horizontal = 24.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = "+",
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.primary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = "new window",
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.primary,
                    fontSize = 14.sp
                )
            }
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun WindowRow(
    window: TmuxWindow,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
            .padding(vertical = 6.dp, horizontal = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = "›",
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 16.sp
        )
        Text(
            text = window.title,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = 14.sp,
            maxLines = 1
        )
    }
}
