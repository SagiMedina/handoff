package com.handoff.app.ui.screens

import com.handoff.app.BuildConfig

import android.content.Context
import android.graphics.Typeface
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.background
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.handoff.app.data.ConfigStore
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.friendlyConnectionError
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.data.TerminalSessionHolder
import androidx.compose.runtime.collectAsState
import com.handoff.app.ui.theme.HandoffAmber
import com.handoff.app.ui.theme.HandoffAmberDim
import com.handoff.app.ui.components.MobileToolbar
import com.handoff.app.ui.components.ModifierState
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun TerminalScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    tailscaleManager: TailscaleManager,
    terminalHolder: TerminalSessionHolder,
    sessionName: String,
    windowIndex: Int,
    onDisconnect: () -> Unit
) {
    var error by remember { mutableStateOf<String?>(null) }
    var termView by remember { mutableStateOf<TerminalView?>(null) }
    val modifiers = remember { ModifierState() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val configStore = remember { ConfigStore(context.applicationContext) }
    val fontSize by configStore.terminalFontSize
        .collectAsState(initial = ConfigStore.DEFAULT_TERMINAL_FONT_SIZE)
    var appliedFontSize by remember { mutableStateOf(-1) }

    val viewClient = remember {
        object : TerminalViewClient {
            override fun onScale(scale: Float): Float = scale
            override fun onSingleTapUp(e: MotionEvent?) {
                termView?.let { view ->
                    view.requestFocus()
                    val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    imm.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
                }
            }
            override fun shouldBackButtonBeMappedToEscape(): Boolean = false
            override fun shouldEnforceCharBasedInput(): Boolean = true
            override fun shouldUseCtrlSpaceWorkaround(): Boolean = false
            override fun isTerminalViewSelected(): Boolean = true
            override fun copyModeChanged(copyMode: Boolean) {}
            override fun onKeyDown(keyCode: Int, e: KeyEvent?, session: TerminalSession?): Boolean {
                // Shift+Enter from the soft/hardware keyboard: emit LF instead of CR so
                // Claude Code treats it as newline-without-submit.
                if (keyCode == KeyEvent.KEYCODE_ENTER && modifiers.shift) {
                    modifiers.shift = false
                    val os = terminalHolder.outputStream ?: return true
                    scope.launch(Dispatchers.IO) {
                        try { os.write(10); os.flush() } catch (_: Exception) {}
                    }
                    return true
                }
                return false
            }
            override fun onKeyUp(keyCode: Int, e: KeyEvent?): Boolean = false
            override fun onLongPress(event: MotionEvent?): Boolean = false
            override fun readControlKey(): Boolean = modifiers.consumeCtrl()
            override fun readAltKey(): Boolean = modifiers.consumeAlt()
            override fun readShiftKey(): Boolean = modifiers.consumeShift()
            override fun readFnKey(): Boolean = false
            override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?): Boolean = false
            override fun onEmulatorSet() {
                termView?.let { view ->
                    val emulator = view.mEmulator ?: return
                    terminalHolder.sshManager.resizeShell(emulator.mColumns, emulator.mRows)
                }
            }
            override fun logError(tag: String?, message: String?) {}
            override fun logWarn(tag: String?, message: String?) {}
            override fun logInfo(tag: String?, message: String?) {}
            override fun logDebug(tag: String?, message: String?) {}
            override fun logVerbose(tag: String?, message: String?) {}
            override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {}
            override fun logStackTrace(tag: String?, e: Exception?) {}
        }
    }

    // On leaving the screen, just detach the view — the holder keeps the SSH channel,
    // emulator, and reader thread alive so re-entry is instant and scrollback survives.
    DisposableEffect(Unit) {
        onDispose {
            if (terminalHolder.currentView === termView) {
                terminalHolder.currentView = null
            }
        }
    }

    LaunchedEffect(sessionName, windowIndex) {
        while (termView == null) { delay(50) }
        val view = termView!!
        while (view.width == 0 || view.height == 0) { delay(50) }

        try {
            val (cols, rows) = terminalHolder.connectAndAttach(
                config, sessionName, windowIndex, view, tailscaleManager
            )
            terminalHolder.currentView = view
            if (BuildConfig.DEBUG) Log.d("Handoff", "Terminal attached: ${cols}x${rows}")

            // Show the keyboard after we're attached.
            view.post {
                view.requestFocus()
                val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                imm.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
            }
        } catch (e: Exception) {
            if (BuildConfig.DEBUG) Log.e("Handoff", "SSH failed", e)
            error = friendlyConnectionError(e)
        }
    }

    if (error != null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
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
                Button(onClick = onDisconnect) { Text("Back") }
            }
        }
        return
    }

    val isReadOnly = sshManager.devicePermissions?.readOnly == true

    Column(modifier = Modifier.fillMaxSize()
        .windowInsetsPadding(WindowInsets.statusBars)
        .imePadding()
    ) {
        if (isReadOnly) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(HandoffAmberDim)
                    .padding(horizontal = 12.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    text = "READ-ONLY",
                    color = HandoffAmber,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.sp
                )
                Text(
                    text = "  ·  viewing only, input disabled",
                    color = HandoffAmber.copy(alpha = 0.6f),
                    fontSize = 11.sp
                )
            }
        }

        AndroidView(
            factory = { ctx ->
                TerminalView(ctx, null).apply {
                    setTerminalViewClient(viewClient)
                    setTextSize(fontSize)
                    appliedFontSize = fontSize
                    val font = Typeface.createFromAsset(ctx.assets, "JetBrainsMono-Regular.ttf")
                    setTypeface(font)
                    isFocusable = true
                    isFocusableInTouchMode = true
                    keepScreenOn = true
                    termView = this
                }
            },
            update = { view ->
                // Re-apply text size when the user drags the Settings slider. Changing the
                // size re-locks the PTY rows/cols to the new grid; TerminalView triggers
                // the underlying resize via its onSizeChanged path.
                if (appliedFontSize != fontSize) {
                    view.setTextSize(fontSize)
                    appliedFontSize = fontSize
                }
            },
            modifier = Modifier.fillMaxWidth().weight(1f)
        )

        MobileToolbar(
            modifiers = modifiers,
            onKey = { bytes ->
                scope.launch(Dispatchers.IO) {
                    val os = terminalHolder.outputStream ?: return@launch
                    try {
                        os.write(bytes)
                        os.flush()
                    } catch (e: Exception) {
                        Log.e("Handoff", "Toolbar write failed: ${e.javaClass.simpleName}: ${e.message}")
                    }
                }
            }
        )
    }
}
