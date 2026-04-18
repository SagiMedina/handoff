package com.handoff.app.data

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import com.handoff.app.BuildConfig
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.OutputStream

/**
 * Activity-scoped holder for the live terminal connection — SSH channel, emulator, and
 * byte streams — that persists across navigation in and out of the terminal screen.
 *
 * The per-screen TerminalView is created fresh on each entry (Compose owns its lifecycle)
 * and reattaches to the cached TerminalSession, so the local emulator grid, scrollback,
 * and the SSH reader thread stay alive and continue to absorb output even while the user
 * is on the sessions list.
 *
 * Only one terminal is cached at a time. Entering a different (sessionName, windowIndex)
 * tears down the previous channel before opening a new one.
 */
class TerminalSessionHolder(private val appContext: Context) {

    val sshManager = SshManager()

    var session: TerminalSession? = null
        private set
    var outputStream: OutputStream? = null
        private set

    private var currentSessionName: String? = null
    private var currentWindowIndex: Int? = null

    // The TerminalView currently attached to the session. Null while transitioning between
    // screens; the reader thread keeps updating the emulator either way.
    var currentView: TerminalView? = null

    val sessionClient: TerminalSessionClient = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) {
            currentView?.onScreenUpdated()
        }
        override fun onTitleChanged(changedSession: TerminalSession) {}
        override fun onSessionFinished(finishedSession: TerminalSession) {}
        override fun onBell(session: TerminalSession) {}
        override fun onColorsChanged(session: TerminalSession) {
            currentView?.invalidate()
        }
        override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {
            if (text != null) {
                val clip = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clip.setPrimaryClip(ClipData.newPlainText("terminal", text))
            }
        }
        override fun onPasteTextFromClipboard(session: TerminalSession?) {
            val clip = appContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val text = clip.primaryClip?.getItemAt(0)?.text?.toString()
            if (text != null) session?.getEmulator()?.paste(text)
        }
        override fun onTerminalCursorStateChange(state: Boolean) {}
        override fun setTerminalShellPid(session: TerminalSession, pid: Int) {}
        override fun getTerminalCursorStyle(): Int = 0
        override fun logError(tag: String?, message: String?) {
            if (BuildConfig.DEBUG) Log.e(tag ?: "Handoff", message ?: "")
        }
        override fun logWarn(tag: String?, message: String?) {}
        override fun logInfo(tag: String?, message: String?) {}
        override fun logDebug(tag: String?, message: String?) {}
        override fun logVerbose(tag: String?, message: String?) {}
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {}
        override fun logStackTrace(tag: String?, e: Exception?) {}
    }

    fun matches(sessionName: String, windowIndex: Int): Boolean =
        session != null &&
            currentSessionName == sessionName &&
            currentWindowIndex == windowIndex

    /**
     * Connects if not already connected to (sessionName, windowIndex), then attaches the
     * given view to the (possibly cached) session. Returns the actual emulator dimensions
     * the remote PTY is locked to.
     */
    suspend fun connectAndAttach(
        config: ConnectionConfig,
        sessionName: String,
        windowIndex: Int,
        view: TerminalView,
        tailscaleManager: TailscaleManager,
    ): Pair<Int, Int> {
        if (session != null && !matches(sessionName, windowIndex)) {
            disconnect()
        }

        val existing = session
        if (existing != null) {
            // Reattach the cached session — emulator state (scrollback, cursor) survives.
            view.attachSession(existing)
            view.sizeLocked = true
            val emulator = existing.getEmulator()
            return (emulator?.mColumns ?: 0) to (emulator?.mRows ?: 0)
        }

        // Fresh connect.
        val renderer = view.mRenderer
        val cols = (view.width / renderer.fontWidth).toInt().coerceAtLeast(4)
        val rows = (view.height / renderer.fontLineSpacing).coerceAtLeast(4)
        val newSession = TerminalSession(sessionClient)
        newSession.initializeEmulator(cols, rows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
        view.attachSession(newSession)
        view.sizeLocked = true

        val emulator = view.mEmulator
        val actualCols = emulator?.mColumns ?: cols
        val actualRows = emulator?.mRows ?: rows

        withContext(Dispatchers.IO) {
            val proxyPort = tailscaleManager.getProxyPort().let { port ->
                if (port > 0) port else tailscaleManager.startProxy(config.ip)
            }
            sshManager.connect(config, proxyPort)
            val (input, output) = sshManager.openShell(
                config.tmuxPath, sessionName, windowIndex, actualCols, actualRows
            )
            outputStream = output
            newSession.setOutputStream(output)
            newSession.startReading(input)
        }

        session = newSession
        currentSessionName = sessionName
        currentWindowIndex = windowIndex
        return actualCols to actualRows
    }

    fun disconnect() {
        session?.finishIfRunning()
        session = null
        outputStream = null
        currentSessionName = null
        currentWindowIndex = null
        currentView = null
        sshManager.disconnect()
    }
}
