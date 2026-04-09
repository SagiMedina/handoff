package com.handoff.app.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
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
    val bytes: ByteArray,
    val longPressBytes: ByteArray? = null // sent on long-press instead
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ToolbarKey) return false
        return label == other.label && bytes.contentEquals(other.bytes)
    }
    override fun hashCode(): Int = 31 * label.hashCode() + bytes.contentHashCode()
}

// Matches Termux default extra keys layout:
// Row 1: ESC  /  -  HOME  UP    END  PGUP
// Row 2: TAB  CTRL ALT LEFT DOWN RIGHT PGDN
private val ROW1 = listOf(
    ToolbarKey("ESC", byteArrayOf(27)),
    ToolbarKey("/", "/".toByteArray()),
    ToolbarKey("-", "-".toByteArray(), longPressBytes = "|".toByteArray()),
    ToolbarKey("HOME", byteArrayOf(27, 91, 72)),           // ESC [ H
    ToolbarKey("\u2191", byteArrayOf(27, 91, 65)),          // UP
    ToolbarKey("END", byteArrayOf(27, 91, 70)),             // ESC [ F
    ToolbarKey("PGUP", byteArrayOf(27, 91, 53, 126)),      // ESC [ 5 ~
)

private val ROW2 = listOf(
    ToolbarKey("TAB", byteArrayOf(9)),
    ToolbarKey("CTRL", byteArrayOf()),   // modifier toggle
    ToolbarKey("ALT", byteArrayOf()),    // modifier toggle
    ToolbarKey("\u2190", byteArrayOf(27, 91, 68)),          // LEFT
    ToolbarKey("\u2193", byteArrayOf(27, 91, 66)),          // DOWN
    ToolbarKey("\u2192", byteArrayOf(27, 91, 67)),          // RIGHT
    ToolbarKey("PGDN", byteArrayOf(27, 91, 54, 126)),      // ESC [ 6 ~
)

@Composable
fun MobileToolbar(
    onKey: (ByteArray) -> Unit,
    modifier: Modifier = Modifier
) {
    var ctrlActive by remember { mutableStateOf(false) }
    var altActive by remember { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 2.dp, vertical = 4.dp)
    ) {
        ToolbarRow(ROW1, ctrlActive, altActive, onKey, { ctrlActive = it }, { altActive = it })
        Spacer(modifier = Modifier.height(2.dp))
        ToolbarRow(ROW2, ctrlActive, altActive, onKey, { ctrlActive = it }, { altActive = it })
    }
}

@Composable
private fun ToolbarRow(
    keys: List<ToolbarKey>,
    ctrlActive: Boolean,
    altActive: Boolean,
    onKey: (ByteArray) -> Unit,
    setCtrl: (Boolean) -> Unit,
    setAlt: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically
    ) {
        keys.forEach { key ->
            ToolbarButton(
                key = key,
                ctrlActive = ctrlActive,
                altActive = altActive,
                onKey = onKey,
                setCtrl = setCtrl,
                setAlt = setAlt,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ToolbarButton(
    key: ToolbarKey,
    ctrlActive: Boolean,
    altActive: Boolean,
    onKey: (ByteArray) -> Unit,
    setCtrl: (Boolean) -> Unit,
    setAlt: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    val isCtrl = key.label == "CTRL"
    val isAlt = key.label == "ALT"
    val isActive = (isCtrl && ctrlActive) || (isAlt && altActive)

    val bgColor = if (isActive) MaterialTheme.colorScheme.primary
                  else MaterialTheme.colorScheme.surface
    val textColor = if (isActive) MaterialTheme.colorScheme.onPrimary
                    else MaterialTheme.colorScheme.onSurface

    Box(
        modifier = modifier
            .padding(horizontal = 1.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(bgColor)
            .combinedClickable(
                onClick = {
                    when {
                        isCtrl -> setCtrl(!ctrlActive)
                        isAlt -> setAlt(!altActive)
                        else -> {
                            var bytes = key.bytes
                            if (ctrlActive && bytes.size == 1) {
                                bytes = byteArrayOf((bytes[0].toInt() and 0x1F).toByte())
                                setCtrl(false)
                            }
                            if (altActive) {
                                // Alt sends ESC prefix
                                onKey(byteArrayOf(27))
                                setAlt(false)
                            }
                            onKey(bytes)
                        }
                    }
                },
                onLongClick = if (key.longPressBytes != null) {
                    { onKey(key.longPressBytes) }
                } else null
            )
            .padding(horizontal = 4.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = key.label,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            color = textColor,
            textAlign = TextAlign.Center,
            maxLines = 1
        )
    }
}
