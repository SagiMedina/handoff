package com.handoff.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
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

    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f))
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Session header — long-press to kill (if allowed)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(
                        onClick = {},
                        onLongClick = { if (onKillSession != null) showKillSessionDialog = true }
                    ),
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
                    text = "${session.windowCount} ${if (session.windowCount == 1) "tab" else "tabs"}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (readOnly) {
                    Text(
                        text = "·",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 10.sp
                    )
                    Text(
                        text = "view only",
                        style = MaterialTheme.typography.labelMedium.copy(fontSize = 11.sp),
                        color = HandoffAmber
                    )
                }
            }

            Spacer(modifier = Modifier.height(10.dp))

            if (session.windows.isNotEmpty()) {
                val dividerColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f)
                session.windows.forEachIndexed { index, window ->
                    if (index > 0) {
                        // Thin divider between windows, indented to align with text
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp)
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
                        onClick = { onWindowClick(window) },
                        onLongClick = { if (onKillWindow != null) windowToKill = window }
                    )
                }
            }

            if (onNewWindow != null) {
                Spacer(modifier = Modifier.height(8.dp))

                // New window button — visually distinct
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .clickable(onClick = onNewWindow)
                        .dashedBorder(
                            color = MaterialTheme.colorScheme.primary.copy(alpha = 0.35f),
                            shape = RoundedCornerShape(8.dp),
                            strokeWidth = 1.dp,
                            dashLength = 6.dp,
                            gapLength = 4.dp
                        )
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "+ new tab",
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.7f),
                        fontSize = 13.sp
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowRow(
    window: TmuxWindow,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
            .padding(vertical = 10.dp, horizontal = 24.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
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
}
