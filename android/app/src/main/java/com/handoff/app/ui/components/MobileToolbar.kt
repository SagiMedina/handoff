package com.handoff.app.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.PointerEventTimeoutCancellationException
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.withTimeout

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
    val longPressBytes: ByteArray? = null, // sent on long-press instead
    // If true, holding the key past the long-press threshold keeps emitting
    // `longPressBytes` every ~80ms until released. Used on arrow keys so
    // holding LEFT/RIGHT keeps jumping words.
    val longPressRepeat: Boolean = false,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ToolbarKey) return false
        return label == other.label && bytes.contentEquals(other.bytes)
    }
    override fun hashCode(): Int = 31 * label.hashCode() + bytes.contentHashCode()
}

// Row 1: ESC  /    -    HOME  UP   END   SHIFT
// Row 2: TAB  CTRL ALT  LEFT  DOWN RIGHT ENTER
//
// Long-press behavior (readline / bash conventions):
//   ESC   → Ctrl-C (interrupt)
//   -     → |
//   UP    → PGUP
//   DOWN  → PGDN
//   LEFT  → Alt+b (backward word)
//   RIGHT → Alt+f (forward word)
private val ROW1 = listOf(
    ToolbarKey("ESC", byteArrayOf(27), longPressBytes = byteArrayOf(3)),  // Ctrl-C
    ToolbarKey("/", "/".toByteArray()),
    ToolbarKey("-", "-".toByteArray(), longPressBytes = "|".toByteArray()),
    ToolbarKey("HOME", byteArrayOf(27, 91, 72)),            // ESC [ H
    ToolbarKey("\u2191", byteArrayOf(27, 91, 65),           // UP
        longPressBytes = byteArrayOf(27, 91, 53, 126)),      // PGUP  (ESC [ 5 ~)
    ToolbarKey("END", byteArrayOf(27, 91, 70)),             // ESC [ F
    ToolbarKey("SHIFT", byteArrayOf()),  // modifier toggle
)

private val ROW2 = listOf(
    ToolbarKey("TAB", byteArrayOf(9)),
    ToolbarKey("CTRL", byteArrayOf()),   // modifier toggle
    ToolbarKey("ALT", byteArrayOf()),    // modifier toggle
    ToolbarKey("\u2190", byteArrayOf(27, 91, 68),           // LEFT
        longPressBytes = byteArrayOf(27, 98),                // Alt+b (backward word)
        longPressRepeat = true),
    ToolbarKey("\u2193", byteArrayOf(27, 91, 66),           // DOWN
        longPressBytes = byteArrayOf(27, 91, 54, 126)),      // PGDN  (ESC [ 6 ~)
    ToolbarKey("\u2192", byteArrayOf(27, 91, 67),           // RIGHT
        longPressBytes = byteArrayOf(27, 102),               // Alt+f (forward word)
        longPressRepeat = true),
    ToolbarKey("\u21B5", byteArrayOf(13)),                   // ENTER (CR)
)

// Hold-to-repeat interval for keys with longPressRepeat (arrows). ~12 reps/sec.
private const val REPEAT_INTERVAL_MS = 80L

/**
 * Apply SHIFT modifier to bytes emitted from the toolbar's own keys.
 *   - Shift+Tab (9)               -> ESC [ Z  (backtab)
 *   - Shift+Enter (CR 13)         -> LF (10)  (newline without submit; Claude Code treats this as shift+enter)
 *   - Shift+Arrow (ESC [ A-D)     -> ESC [ 1 ; 2 <letter>  (text selection)
 */
private fun applyShift(bytes: ByteArray): ByteArray {
    if (bytes.size == 1 && bytes[0] == 9.toByte()) {
        return byteArrayOf(27, 91, 90)
    }
    if (bytes.size == 1 && bytes[0] == 13.toByte()) {
        return byteArrayOf(10)
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

    val onTap: () -> Unit = {
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
    }

    // Keys with longPressRepeat use a custom press-and-hold gesture that keeps firing
    // longPressBytes every ~80ms until released — so holding LEFT keeps jumping words.
    // Every other key uses combinedClickable for the familiar one-shot long-press.
    //
    // waitForUpOrCancellation() returns three distinct outcomes we must handle:
    //   - non-null PointerInputChange → pointer went up (tap or release)
    //   - null                        → gesture was CANCELLED (parent took over)
    //   - PointerEventTimeoutCancellationException → the withTimeout window expired
    //
    // Cancellation MUST break out of the repeat loop. An earlier version treated
    // `null` identically to "timeout while still holding", which meant a cancelled
    // gesture kept firing Alt+b every 80ms forever — observed as runaway `^[b`
    // flooding tmux as soon as the terminal view reclaimed pointer focus.
    val gestureModifier = if (key.longPressRepeat && key.longPressBytes != null) {
        Modifier.pointerInput(key) {
            awaitEachGesture {
                val down = awaitFirstDown()
                down.consume()
                val lpTimeout = viewConfiguration.longPressTimeoutMillis

                var timedOut = false
                val initial: PointerInputChange? = try {
                    withTimeout(lpTimeout) { waitForUpOrCancellation() }
                } catch (_: PointerEventTimeoutCancellationException) {
                    timedOut = true
                    null
                }

                when {
                    // Pointer went up before long-press threshold → tap.
                    initial != null -> onTap()
                    // Long-press threshold reached while still holding → enter repeat.
                    timedOut -> {
                        val lpBytes = key.longPressBytes
                        onKey(lpBytes)
                        var active = true
                        while (active) {
                            try {
                                withTimeout(REPEAT_INTERVAL_MS) {
                                    // Either non-null (up) or null (cancelled) stops the
                                    // repeat. We only keep firing on the timeout branch.
                                    waitForUpOrCancellation()
                                    active = false
                                }
                            } catch (_: PointerEventTimeoutCancellationException) {
                                onKey(lpBytes)
                            }
                        }
                    }
                    // Otherwise: cancelled before long-press threshold — do nothing.
                }
            }
        }
    } else {
        Modifier.combinedClickable(
            onClick = onTap,
            onLongClick = if (key.longPressBytes != null) {
                { onKey(key.longPressBytes) }
            } else null,
        )
    }

    Box(
        modifier = modifier
            .padding(horizontal = 1.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(bgColor)
            .then(gestureModifier)
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
