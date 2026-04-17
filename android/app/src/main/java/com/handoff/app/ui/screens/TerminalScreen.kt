package com.handoff.app.ui.screens

import com.handoff.app.BuildConfig

import android.content.ClipboardManager
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.friendlyConnectionError
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.ui.theme.HandoffAmber
import com.handoff.app.ui.theme.HandoffAmberDim
import com.handoff.app.ui.components.MobileToolbar
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.OutputStream

@Composable
fun TerminalScreen(
    config: ConnectionConfig,
    sshManager: SshManager,
    tailscaleManager: TailscaleManager,
    sessionName: String,
    windowIndex: Int,
    onDisconnect: () -> Unit
) {
    var sshReady by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var outputStream by remember { mutableStateOf<OutputStream?>(null) }
    var termView by remember { mutableStateOf<TerminalView?>(null) }
    val terminalSsh = remember { SshManager() }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    val sessionClient = remember {
        object : TerminalSessionClient {
            override fun onTextChanged(changedSession: TerminalSession) {
                val view = termView
                if (view != null) {
                    view.onScreenUpdated()
                } else {
                    if (BuildConfig.DEBUG) Log.w("Handoff", "onTextChanged but termView is null!")
                }
            }
            override fun onTitleChanged(changedSession: TerminalSession) {}
            override fun onSessionFinished(finishedSession: TerminalSession) {}
            override fun onBell(session: TerminalSession) {}
            override fun onColorsChanged(session: TerminalSession) {
                termView?.invalidate()
            }
            override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {
                if (text != null) {
                    val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clip.setPrimaryClip(android.content.ClipData.newPlainText("terminal", text))
                }
            }
            override fun onPasteTextFromClipboard(session: TerminalSession?) {
                val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val text = clip.primaryClip?.getItemAt(0)?.text?.toString()
                if (text != null) session?.getEmulator()?.paste(text)
            }
            override fun onTerminalCursorStateChange(state: Boolean) {}
            override fun setTerminalShellPid(session: TerminalSession, pid: Int) {}
            override fun getTerminalCursorStyle(): Int = 0
            override fun logError(tag: String?, message: String?) { if (BuildConfig.DEBUG) Log.e(tag ?: "Handoff", message ?: "") }
            override fun logWarn(tag: String?, message: String?) {}
            override fun logInfo(tag: String?, message: String?) {}
            override fun logDebug(tag: String?, message: String?) {}
            override fun logVerbose(tag: String?, message: String?) {}
            override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {}
            override fun logStackTrace(tag: String?, e: Exception?) {}
        }
    }

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
            override fun onKeyDown(keyCode: Int, e: KeyEvent?, session: TerminalSession?): Boolean = false
            override fun onKeyUp(keyCode: Int, e: KeyEvent?): Boolean = false
            override fun onLongPress(event: MotionEvent?): Boolean = false
            override fun readControlKey(): Boolean = false
            override fun readAltKey(): Boolean = false
            override fun readShiftKey(): Boolean = false
            override fun readFnKey(): Boolean = false
            override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?): Boolean = false
            override fun onEmulatorSet() {
                termView?.let { view ->
                    // Notify SSH of the terminal size once emulator is ready
                    val emulator = view.mEmulator ?: return
                    terminalSsh.resizeShell(emulator.mColumns, emulator.mRows)
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

    // Clean up terminal SSH on leave
    DisposableEffect(Unit) {
        onDispose { terminalSsh.disconnect() }
    }

    // Connect SSH once after TerminalView is created, keyboard shown, and view stabilized
    LaunchedEffect(Unit) {
        // Wait for termView to be set by AndroidView factory
        while (termView == null) { delay(50) }
        val view = termView!!

        // Wait for view to have real dimensions
        while (view.width == 0 || view.height == 0) { delay(50) }

        // Show keyboard FIRST — so the view resizes before we calculate terminal dimensions
        view.post {
            view.requestFocus()
            val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
        }

        // Wait for keyboard animation to settle (view height stabilizes)
        var lastHeight = view.height
        delay(400)
        while (true) {
            delay(100)
            if (view.height == lastHeight) break
            lastHeight = view.height
        }

        // Now calculate terminal size with keyboard visible
        val session = TerminalSession(sessionClient)
        val renderer = view.mRenderer
        val cols = (view.width / renderer.fontWidth).toInt().coerceAtLeast(4)
        val rows = (view.height / renderer.fontLineSpacing).coerceAtLeast(4)
        session.initializeEmulator(cols, rows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
        view.attachSession(session)

        val emulator = view.mEmulator
        val actualCols = emulator?.mColumns ?: cols
        val actualRows = emulator?.mRows ?: rows
        if (BuildConfig.DEBUG) Log.d("Handoff", "Terminal: ${actualCols}x${actualRows} (after keyboard)")

        try {
            val proxyPort = tailscaleManager.getProxyPort().let { port ->
                if (port > 0) port else tailscaleManager.startProxy(config.ip)
            }
            terminalSsh.connect(config, proxyPort)
            val (input, output) = terminalSsh.openShell(
                config.tmuxPath, sessionName, windowIndex, actualCols, actualRows
            )
            outputStream = output
            session.setOutputStream(output)
            session.startReading(input)
            sshReady = true
            if (BuildConfig.DEBUG) Log.d("Handoff", "SSH ready")
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
        // Read-only indicator bar
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
                    setTextSize(24)
                    // JetBrains Mono for broad Unicode coverage (❯, ●, box drawing, etc.)
                    // Android's font fallback handles remaining chars (braille, dingbats).
                    val font = Typeface.createFromAsset(ctx.assets, "JetBrainsMono-Regular.ttf")
                    setTypeface(font)
                    isFocusable = true
                    isFocusableInTouchMode = true
                    keepScreenOn = true

                    // Compose's imePadding() changes this view's bounds when the
                    // keyboard shows/hides, but onSizeChanged may not fire reliably
                    // through AndroidView. Explicitly trigger terminal resize.
                    addOnLayoutChangeListener { v, left, top, right, bottom,
                                                oldLeft, oldTop, oldRight, oldBottom ->
                        if ((right - left) != (oldRight - oldLeft) ||
                            (bottom - top) != (oldBottom - oldTop)) {
                            v.post { (v as TerminalView).updateSize() }
                        }
                    }

                    termView = this
                }
            },
            modifier = Modifier.fillMaxWidth().weight(1f)
        )

        MobileToolbar(
            onKey = { bytes ->
                scope.launch(Dispatchers.IO) {
                    try {
                        outputStream?.write(bytes)
                        outputStream?.flush()
                    } catch (_: Exception) {}
                }
            }
        )
    }
}
