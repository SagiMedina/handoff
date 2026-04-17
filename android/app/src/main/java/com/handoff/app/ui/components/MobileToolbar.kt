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

/**
 * Sticky-key modifier state shared between the toolbar and TerminalView. Tapping a
 * modifier on the toolbar flips the flag; the next keystroke (from the toolbar OR the
 * soft/hardware keyboard) reads and clears the flag, so e.g. tapping SHIFT then pressing
 * Enter on the soft keyboard produces Shift+Enter as far as the terminal is concerned.
 *
 * TerminalView already consults read{Shift,Control,Alt,Fn}Key() on every input path
 * (commitText, sendKeyEvent, inputCodePoint, onKeyDown), so wiring the client to consume
 * from this state is enough to make modifiers chain across both input sources.
 */
class ModifierState {
    var ctrl by mutableStateOf(false)
    var alt by mutableStateOf(false)
    var shift by mutableStateOf(false)

    fun consumeCtrl(): Boolean = ctrl.also { if (it) ctrl = false }
    fun consumeAlt(): Boolean = alt.also { if (it) alt = false }
    fun consumeShift(): Boolean = shift.also { if (it) shift = false }
}

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

// Row 1: ESC  /    -    HOME  UP   END   ENTER
// Row 2: TAB  CTRL ALT  LEFT  DOWN RIGHT SHIFT
private val ROW1 = listOf(
    ToolbarKey("ESC", byteArrayOf(27)),
    ToolbarKey("/", "/".toByteArray()),
    ToolbarKey("-", "-".toByteArray(), longPressBytes = "|".toByteArray()),
    ToolbarKey("HOME", byteArrayOf(27, 91, 72)),           // ESC [ H
    ToolbarKey("\u2191", byteArrayOf(27, 91, 65)),          // UP
    ToolbarKey("END", byteArrayOf(27, 91, 70)),             // ESC [ F
    ToolbarKey("\u21B5", byteArrayOf(13)),                  // ENTER (CR)
)

private val ROW2 = listOf(
    ToolbarKey("TAB", byteArrayOf(9)),
    ToolbarKey("CTRL", byteArrayOf()),   // modifier toggle
    ToolbarKey("ALT", byteArrayOf()),    // modifier toggle
    ToolbarKey("\u2190", byteArrayOf(27, 91, 68)),          // LEFT
    ToolbarKey("\u2193", byteArrayOf(27, 91, 66)),          // DOWN
    ToolbarKey("\u2192", byteArrayOf(27, 91, 67)),          // RIGHT
    ToolbarKey("SHIFT", byteArrayOf()),  // modifier toggle
)

/**
 * Apply SHIFT modifier to bytes emitted from the toolbar's own keys.
 *   - Shift+Tab (9)               -> ESC [ Z  (backtab)
 *   - Shift+Arrow (ESC [ A-D)     -> ESC [ 1 ; 2 <letter>  (text selection)
 */
private fun applyShift(bytes: ByteArray): ByteArray {
    if (bytes.size == 1 && bytes[0] == 9.toByte()) {
        return byteArrayOf(27, 91, 90)
    }
    if (bytes.size == 3 && bytes[0] == 27.toByte() && bytes[1] == 91.toByte()) {
        val letter = bytes[2]
        if (letter in byteArrayOf(65, 66, 67, 68)) {
            return byteArrayOf(27, 91, 49, 59, 50, letter)
        }
    }
    return bytes
}

@Composable
fun MobileToolbar(
    modifiers: ModifierState,
    onKey: (ByteArray) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 2.dp, vertical = 4.dp)
    ) {
        ToolbarRow(ROW1, modifiers, onKey)
        Spacer(modifier = Modifier.height(2.dp))
        ToolbarRow(ROW2, modifiers, onKey)
    }
}

@Composable
private fun ToolbarRow(
    keys: List<ToolbarKey>,
    modifiers: ModifierState,
    onKey: (ByteArray) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically
    ) {
        keys.forEach { key ->
            ToolbarButton(
                key = key,
                modifiers = modifiers,
                onKey = onKey,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ToolbarButton(
    key: ToolbarKey,
    modifiers: ModifierState,
    onKey: (ByteArray) -> Unit,
    modifier: Modifier = Modifier
) {
    val isCtrl = key.label == "CTRL"
    val isAlt = key.label == "ALT"
    val isShift = key.label == "SHIFT"
    val isActive = (isCtrl && modifiers.ctrl) ||
                   (isAlt && modifiers.alt) ||
                   (isShift && modifiers.shift)

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
                        isCtrl -> modifiers.ctrl = !modifiers.ctrl
                        isAlt -> modifiers.alt = !modifiers.alt
                        isShift -> modifiers.shift = !modifiers.shift
                        else -> {
                            var bytes = key.bytes
                            if (modifiers.consumeCtrl() && bytes.size == 1) {
                                bytes = byteArrayOf((bytes[0].toInt() and 0x1F).toByte())
                            }
                            if (modifiers.consumeShift()) {
                                bytes = applyShift(bytes)
                            }
                            if (modifiers.consumeAlt()) {
                                // Alt sends ESC prefix
                                onKey(byteArrayOf(27))
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
