package com.handoff.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

data class ToolbarKey(
    val label: String,
    val bytes: ByteArray // what to send over SSH
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ToolbarKey) return false
        return label == other.label && bytes.contentEquals(other.bytes)
    }
    override fun hashCode(): Int = 31 * label.hashCode() + bytes.contentHashCode()
}

private val TOOLBAR_KEYS = listOf(
    ToolbarKey("ESC", byteArrayOf(27)),
    ToolbarKey("TAB", byteArrayOf(9)),
    ToolbarKey("CTRL", byteArrayOf()), // modifier, handled specially
    ToolbarKey("↑", byteArrayOf(27, 91, 65)),
    ToolbarKey("↓", byteArrayOf(27, 91, 66)),
    ToolbarKey("→", byteArrayOf(27, 91, 67)),
    ToolbarKey("←", byteArrayOf(27, 91, 68)),
    ToolbarKey("|", "|".toByteArray()),
    ToolbarKey("~", "~".toByteArray()),
    ToolbarKey("/", "/".toByteArray()),
    ToolbarKey("-", "-".toByteArray()),
)

@Composable
fun MobileToolbar(
    onKey: (ByteArray) -> Unit,
    modifier: Modifier = Modifier
) {
    var ctrlActive by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 4.dp, vertical = 6.dp)
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        TOOLBAR_KEYS.forEach { key ->
            val isCtrl = key.label == "CTRL"
            val bgColor = when {
                isCtrl && ctrlActive -> MaterialTheme.colorScheme.primary
                else -> MaterialTheme.colorScheme.surface
            }
            val textColor = when {
                isCtrl && ctrlActive -> MaterialTheme.colorScheme.onPrimary
                else -> MaterialTheme.colorScheme.onSurface
            }

            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .background(bgColor)
                    .clickable {
                        if (isCtrl) {
                            ctrlActive = !ctrlActive
                        } else if (ctrlActive && key.bytes.size == 1) {
                            // Send Ctrl+key (ASCII 1-26 for a-z)
                            val b = key.bytes[0]
                            val ctrlByte = (b.toInt() and 0x1F).toByte()
                            onKey(byteArrayOf(ctrlByte))
                            ctrlActive = false
                        } else {
                            onKey(key.bytes)
                            ctrlActive = false
                        }
                    }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = key.label,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    color = textColor,
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}
