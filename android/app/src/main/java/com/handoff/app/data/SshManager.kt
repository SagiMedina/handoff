package com.handoff.app.data

import com.handoff.app.BuildConfig

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
    private var protocolVersion: Int = 1
    var devicePermissions: DevicePermissions? = null
        private set

    suspend fun connect(config: ConnectionConfig, proxyPort: Int = 0) = withContext(Dispatchers.IO) {
        disconnect()
        protocolVersion = config.protocolVersion

        // Ensure BouncyCastle is available for Ed25519 key support
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.insertProviderAt(BouncyCastleProvider(), 1)
        }

        val jsch = JSch()
        val keyBytes = Base64.getDecoder().decode(config.privateKey)
        if (BuildConfig.DEBUG) Log.d("Handoff", "Key bytes length: ${keyBytes.size}, starts with: ${String(keyBytes.take(30).toByteArray())}")
        jsch.addIdentity("handoff", keyBytes, null, null)

        val host = if (proxyPort > 0) "127.0.0.1" else config.ip
        val port = if (proxyPort > 0) proxyPort else 22
        val sess = jsch.getSession(config.user, host, port)
        val props = Properties()
        props["StrictHostKeyChecking"] = "no"
        sess.setConfig(props)
        sess.setServerAliveInterval(15_000)
        sess.setServerAliveCountMax(3)
        sess.connect(10_000)
        session = sess
        if (BuildConfig.DEBUG) Log.d("Handoff", "SSH connected via JSch (protocol v$protocolVersion)")
    }

    suspend fun listSessions(tmuxPath: String): List<TmuxSession> = withContext(Dispatchers.IO) {
        val command = if (protocolVersion >= 2) "list"
            else "$tmuxPath list-sessions -F '#{session_name}:#{session_windows}'"
        val output = executeCommand(command)
        if (output.isBlank()) return@withContext emptyList()

        val lines = output.trim().lines().toMutableList()

        // v2: parse #permissions: header
        if (protocolVersion >= 2 && lines.isNotEmpty() && lines[0].startsWith("#permissions:")) {
            devicePermissions = parsePermissionsHeader(lines.removeAt(0))
        }

        // Check for gate errors
        if (lines.size == 1 && lines[0].startsWith("error:")) {
            throw GateException(lines[0])
        }

        lines.map { line ->
            val parts = line.split(":")
            val name = parts[0]
            val windowCount = parts.getOrNull(1)?.toIntOrNull() ?: 0
            TmuxSession(name, windowCount)
        }
    }

    suspend fun listWindows(tmuxPath: String, sessionName: String): List<TmuxWindow> = withContext(Dispatchers.IO) {
        val command = if (protocolVersion >= 2) "windows $sessionName"
            else "$tmuxPath list-windows -t '$sessionName' -F '#{window_index}|#{pane_title}|#{pane_current_command}|#{pane_current_path}'"
        val output = executeCommand(command)
        if (output.isBlank()) return@withContext emptyList()

        // Check for gate errors
        val trimmed = output.trim()
        if (trimmed.startsWith("error:")) throw GateException(trimmed)

        trimmed.lines().map { line ->
            val parts = line.split("|", limit = 4)
            val rawPath = parts.getOrElse(3) { "" }
            TmuxWindow(
                index = parts[0].toIntOrNull() ?: 0,
                title = (parts.getOrElse(1) { "" }.ifBlank { parts.getOrElse(2) { "shell" } })
                    .replace(Regex("^[^\\p{L}\\p{N}]+"), "").trim(),
                command = parts.getOrElse(2) { "" },
                cwd = rawPath.trimEnd('/').substringAfterLast('/')
            )
        }
    }

    suspend fun createSession(tmuxPath: String, sessionName: String): Unit = withContext(Dispatchers.IO) {
        val command = if (protocolVersion >= 2) "create-session $sessionName"
            else "$tmuxPath new-session -d -s '$sessionName'"
        val output = executeCommand(command).trim()
        if (output.startsWith("error:")) throw GateException(output)
    }

    suspend fun killSession(tmuxPath: String, sessionName: String): Unit = withContext(Dispatchers.IO) {
        val command = if (protocolVersion >= 2) "kill-session $sessionName"
            else "$tmuxPath kill-session -t '$sessionName'"
        val output = executeCommand(command).trim()
        if (output.startsWith("error:")) throw GateException(output)
    }

    suspend fun killWindow(tmuxPath: String, sessionName: String, windowIndex: Int): Unit = withContext(Dispatchers.IO) {
        val command = if (protocolVersion >= 2) "kill-window $sessionName $windowIndex"
            else "$tmuxPath kill-window -t '$sessionName:$windowIndex'"
        val output = executeCommand(command).trim()
        if (output.startsWith("error:")) throw GateException(output)
    }

    suspend fun createWindow(tmuxPath: String, sessionName: String): Int = withContext(Dispatchers.IO) {
        val command = if (protocolVersion >= 2) "create-window $sessionName"
            else "$tmuxPath new-window -t '$sessionName' -P -F '#{window_index}'"
        val output = executeCommand(command).trim()
        if (output.startsWith("error:")) throw GateException(output)
        output.toIntOrNull() ?: -1
    }

    suspend fun openShell(
        tmuxPath: String,
        sessionName: String,
        windowIndex: Int,
        cols: Int,
        rows: Int
    ): Pair<InputStream, OutputStream> = withContext(Dispatchers.IO) {
        val sess = session ?: throw IllegalStateException("Not connected")

        val channel = sess.openChannel("exec") as ChannelExec
        channel.setPtyType("xterm-256color", cols, rows, cols * 8, rows * 16)
        channel.setPty(true)

        // v2: gate handles LANG and tmux attach. v1: raw tmux command.
        val command = if (protocolVersion >= 2) "attach $sessionName $windowIndex"
            else "export LANG=en_US.UTF-8; $tmuxPath attach -t '${sessionName}:${windowIndex}'"
        channel.setCommand(command)

        val inputFromRemote = channel.inputStream
        val outputToRemote = channel.outputStream

        channel.connect(10_000)
        shellChannel = channel

        if (BuildConfig.DEBUG) Log.d("Handoff", "Exec channel connected (v$protocolVersion): $command")

        Pair(inputFromRemote, outputToRemote)
    }

    // v2: send pair command during verification handshake
    // Includes device model name so the Mac can identify this phone
    suspend fun sendPairCommand(deviceName: String = ""): String = withContext(Dispatchers.IO) {
        val name = deviceName.ifBlank {
            "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim()
        }
        val output = executeCommand("pair $name").trim()
        if (output.startsWith("error:")) throw GateException(output)
        output  // "verify:<code>"
    }

    // v2: request access renewal when expired
    suspend fun requestRenewal(): String = withContext(Dispatchers.IO) {
        val output = executeCommand("renew").trim()
        if (output.startsWith("error:")) throw GateException(output)
        output  // "requested"
    }

    fun resizeShell(cols: Int, rows: Int) {
        pendingResize?.let { resizeHandler.removeCallbacks(it) }
        pendingResize = Runnable {
            val ch = shellChannel ?: return@Runnable
            if (BuildConfig.DEBUG) Log.d("Handoff", "resizeShell: ${cols}x${rows}")
            ch.setPtySize(cols, rows, cols * 8, rows * 16)
        }
        resizeHandler.postDelayed(pendingResize!!, 150)
    }

    private fun parsePermissionsHeader(header: String): DevicePermissions {
        // Format: #permissions:read_only=false,sessions=main;work-*
        val params = header.removePrefix("#permissions:").split(",")
        var readOnly = false
        var sessions = listOf("*")
        for (param in params) {
            val (key, value) = param.split("=", limit = 2)
            when (key) {
                "read_only" -> readOnly = value == "true"
                "sessions" -> sessions = value.split(";")
            }
        }
        return DevicePermissions(readOnly, sessions)
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
        devicePermissions = null
    }

    val isConnected: Boolean
        get() = session?.isConnected == true
}

class GateException(val gateError: String) : Exception(gateError)
