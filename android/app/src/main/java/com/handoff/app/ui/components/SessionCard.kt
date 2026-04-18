package com.handoff.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.handoff.app.data.TmuxSession
import com.handoff.app.data.TmuxWindow
import com.handoff.app.ui.theme.HandoffAmber
import com.handoff.app.ui.theme.HandoffGreen

private fun Modifier.dashedBorder(
    color: Color,
    shape: RoundedCornerShape,
    strokeWidth: Dp = 1.dp,
    dashLength: Dp = 6.dp,
    gapLength: Dp = 4.dp
) = this.drawWithContent {
    drawContent()
    val stroke = Stroke(
        width = strokeWidth.toPx(),
        pathEffect = PathEffect.dashPathEffect(
            floatArrayOf(dashLength.toPx(), gapLength.toPx())
        )
    )
    val cornerRadius = shape.topStart.toPx(size, this)
    drawRoundRect(
        color = color,
        style = stroke,
        cornerRadius = CornerRadius(cornerRadius, cornerRadius)
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionCard(
    session: TmuxSession,
    onWindowClick: (TmuxWindow) -> Unit,
    onNewWindow: (() -> Unit)? = null,
    onKillSession: (() -> Unit)? = null,
    onKillWindow: ((TmuxWindow) -> Unit)? = null,
    onToggleWindowPin: ((TmuxWindow) -> Unit)? = null,
    isWindowPinned: (TmuxWindow) -> Boolean = { false },
    readOnly: Boolean = false,
    modifier: Modifier = Modifier
) {
    var showKillSessionDialog by remember { mutableStateOf(false) }
    var windowToKill by remember { mutableStateOf<TmuxWindow?>(null) }

    if (showKillSessionDialog && onKillSession != null) {
        AlertDialog(
            onDismissRequest = { showKillSessionDialog = false },
            title = { Text("Kill session?") },
            text = { Text("This will close all ${session.windowCount} tabs in \"${session.name}\".") },
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
        if (onKillWindow != null) {
            AlertDialog(
                onDismissRequest = { windowToKill = null },
                title = { Text("Kill tab?") },
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
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            // Subtle surface lift instead of a full Material Card. The page background
            // is near-black; a single step up (surface) separates the card without
            // needing a border, which would fight the terminal aesthetic.
            .background(
                color = MaterialTheme.colorScheme.surface,
                shape = RoundedCornerShape(8.dp),
            )
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        // Session header — long-press to kill (if allowed). Using a box-drawing glyph
        // instead of a bullet gives the row a terminal-listing feel (lazygit / ranger).
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = {},
                    onLongClick = { if (onKillSession != null) showKillSessionDialog = true }
                ),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "\u25B8",  // ▸
                color = HandoffGreen,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.padding(end = 8.dp),
            )
            Text(
                text = session.name,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = "${session.windowCount} ${if (session.windowCount == 1) "tab" else "tabs"}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
            Spacer(modifier = Modifier.weight(1f))
            if (readOnly) {
                // Compact monospace badge. No pill background — the amber is the signal.
                Text(
                    text = "ro",
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontWeight = FontWeight.Bold,
                    ),
                    color = HandoffAmber,
                )
            }
        }

        Spacer(modifier = Modifier.height(6.dp))

        if (session.windows.isNotEmpty()) {
            val dividerColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.08f)
            session.windows.forEachIndexed { index, window ->
                if (index > 0) {
                    // Hairline divider between tabs, indented past the row glyph so the
                    // visual rhythm follows the text column, not the card edge.
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 28.dp)
                            .height(0.5.dp)
                            .drawBehind {
                                drawLine(
                                    color = dividerColor,
                                    start = Offset(0f, 0f),
                                    end = Offset(size.width, 0f),
                                    strokeWidth = 0.5.dp.toPx()
                                )
                            }
                    )
                }
                WindowRow(
                    window = window,
                    isPinned = isWindowPinned(window),
                    onClick = { onWindowClick(window) },
                    onTogglePin = onToggleWindowPin?.let { cb -> { cb(window) } },
                    onKill = onKillWindow?.let { cb -> { windowToKill = window } },
                )
            }
        }

        if (onNewWindow != null) {
            // Plain low-emphasis text link. Aligns with the tab rows' text column so
            // the "+" sits where the tab glyph would. The dashed border is gone —
            // terminal tools don't decorate affordances, they name them.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onNewWindow)
                    .padding(vertical = 10.dp, horizontal = 24.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "+ ",
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.8f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 14.sp,
                )
                Text(
                    text = "new tab",
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 14.sp,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowRow(
    window: TmuxWindow,
    isPinned: Boolean,
    onClick: () -> Unit,
    onTogglePin: (() -> Unit)?,
    onKill: (() -> Unit)?,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val hasMenu = onTogglePin != null || onKill != null

    Box(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { if (hasMenu) menuExpanded = true },
                )
                .padding(vertical = 10.dp, horizontal = 24.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // Pinned rows get a colored dot in the primary accent; unpinned rows
                // keep the chevron. The 📌 emoji used to live here — it rendered tilted
                // and full-color, clashing with the monospace aesthetic. A dot reads as
                // "this matters" in every CLI context (status lights, unread markers)
                // and harmonizes with the terminal typography.
                if (isPinned) {
                    Text(
                        text = "\u25CF",  // ●
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary,
                        fontSize = 10.sp,
                    )
                } else {
                    Text(
                        text = "\u203A",  // ›
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                        fontSize = 16.sp,
                    )
                }
                Text(
                    text = window.title,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 14.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (window.cwd.isNotBlank()) {
                Text(
                    text = "~/${window.cwd}",
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 22.dp, top = 2.dp)
                )
            }
        }

        DropdownMenu(
            expanded = menuExpanded,
            onDismissRequest = { menuExpanded = false },
        ) {
            if (onTogglePin != null) {
                DropdownMenuItem(
                    text = { Text(if (isPinned) "Unpin" else "Pin to top") },
                    onClick = {
                        menuExpanded = false
                        onTogglePin()
                    },
                )
            }
            if (onKill != null) {
                DropdownMenuItem(
                    text = { Text("Kill tab", color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        menuExpanded = false
                        onKill()
                    },
                )
            }
        }
    }
}
