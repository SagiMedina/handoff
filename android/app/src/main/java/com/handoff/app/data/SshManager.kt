package com.handoff.app.data

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.io.OutputStream
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security
import java.util.Base64
import java.util.Properties

class SshManager {

    private var session: Session? = null
    private var shellChannel: ChannelExec? = null
    private val resizeHandler = Handler(Looper.getMainLooper())
    private var pendingResize: Runnable? = null

    suspend fun connect(config: ConnectionConfig, proxyPort: Int = 0) = withContext(Dispatchers.IO) {
        disconnect()

        // Ensure BouncyCastle is available for Ed25519 key support
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.insertProviderAt(BouncyCastleProvider(), 1)
        }

        val jsch = JSch()
        val keyBytes = Base64.getDecoder().decode(config.privateKey)
        Log.d("Handoff", "Key bytes length: ${keyBytes.size}, starts with: ${String(keyBytes.take(30).toByteArray())}")
        jsch.addIdentity("handoff", keyBytes, null, null)

        val host = if (proxyPort > 0) "127.0.0.1" else config.ip
        val port = if (proxyPort > 0) proxyPort else 22
        val sess = jsch.getSession(config.user, host, port)
        val props = Properties()
        props["StrictHostKeyChecking"] = "no"
        sess.setConfig(props)
        sess.setServerAliveInterval(15_000) // Send keepalive every 15s
        sess.setServerAliveCountMax(3)
        sess.connect(10_000)
        session = sess
        Log.d("Handoff", "SSH connected via JSch")
    }

    suspend fun listSessions(tmuxPath: String): List<TmuxSession> = withContext(Dispatchers.IO) {
        val output = executeCommand("$tmuxPath list-sessions -F '#{session_name}:#{session_windows}'")
        if (output.isBlank()) return@withContext emptyList()

        output.trim().lines().map { line ->
            val parts = line.split(":")
            val name = parts[0]
            val windowCount = parts.getOrNull(1)?.toIntOrNull() ?: 0
            TmuxSession(name, windowCount)
        }
    }

    suspend fun listWindows(tmuxPath: String, sessionName: String): List<TmuxWindow> = withContext(Dispatchers.IO) {
        val output = executeCommand(
            "$tmuxPath list-windows -t '$sessionName' -F '#{window_index}|#{pane_title}|#{pane_current_command}'"
        )
        if (output.isBlank()) return@withContext emptyList()

        output.trim().lines().map { line ->
            val parts = line.split("|", limit = 3)
            TmuxWindow(
                index = parts[0].toIntOrNull() ?: 0,
                title = (parts.getOrElse(1) { "" }.ifBlank { parts.getOrElse(2) { "shell" } })
                    .replace(Regex("^[^\\p{L}\\p{N}]+"), "").trim(), // Strip leading Unicode symbols (e.g. Claude Code status indicators)
                command = parts.getOrElse(2) { "" }
            )
        }
    }

    suspend fun createSession(tmuxPath: String, sessionName: String): Unit = withContext(Dispatchers.IO) {
        executeCommand("$tmuxPath new-session -d -s '$sessionName'")
    }

    suspend fun openShell(
        tmuxPath: String,
        sessionName: String,
        windowIndex: Int,
        cols: Int,
        rows: Int
    ): Pair<InputStream, OutputStream> = withContext(Dispatchers.IO) {
        val sess = session ?: throw IllegalStateException("Not connected")

        // Use exec channel (not shell) — matches `ssh -t host "tmux attach ..."` behavior.
        // Shell channel opens an interactive shell then sends tmux attach as text,
        // which causes race conditions and locks the Mac tmux session.
        val channel = sess.openChannel("exec") as ChannelExec
        channel.setPtyType("xterm-256color", cols, rows, cols * 8, rows * 16)
        channel.setPty(true)
        // Set UTF-8 locale so tmux sends Unicode characters instead of ASCII fallbacks.
        // Without this, tmux replaces ●, ❯, etc. with _ because it assumes non-UTF-8 client.
        channel.setCommand("export LANG=en_US.UTF-8; $tmuxPath attach -t '${sessionName}:${windowIndex}'")

        // Get streams BEFORE connect
        val inputFromRemote = channel.inputStream
        val outputToRemote = channel.outputStream

        channel.connect(10_000)
        shellChannel = channel

        Log.d("Handoff", "Exec channel connected, running: tmux attach -t '${sessionName}:${windowIndex}'")

        Pair(inputFromRemote, outputToRemote)
    }

    fun resizeShell(cols: Int, rows: Int) {
        // Debounce: keyboard animation fires many rapid resize events.
        // Only send the final size to tmux after 150ms of no changes.
        pendingResize?.let { resizeHandler.removeCallbacks(it) }
        pendingResize = Runnable {
            val ch = shellChannel ?: return@Runnable
            Log.d("Handoff", "resizeShell: ${cols}x${rows}")
            ch.setPtySize(cols, rows, cols * 8, rows * 16)
        }
        resizeHandler.postDelayed(pendingResize!!, 150)
    }

    private suspend fun executeCommand(command: String): String = withContext(Dispatchers.IO) {
        val sess = session ?: throw IllegalStateException("Not connected")
        val channel = sess.openChannel("exec") as ChannelExec
        channel.setCommand(command)
        channel.inputStream = null
        val input = channel.inputStream
        channel.connect(10_000)
        val output = input.bufferedReader().readText()
        channel.disconnect()
        output
    }

    fun disconnect() {
        shellChannel?.disconnect()
        shellChannel = null
        session?.disconnect()
        session = null
    }

    val isConnected: Boolean
        get() = session?.isConnected == true
}
