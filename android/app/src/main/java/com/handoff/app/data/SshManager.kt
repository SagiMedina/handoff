package com.handoff.app.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.apache.sshd.client.SshClient
import org.apache.sshd.client.channel.ChannelShell
import org.apache.sshd.client.session.ClientSession
import org.apache.sshd.common.config.keys.loader.pem.PEMResourceParserUtils
import org.apache.sshd.common.util.security.SecurityUtils
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.KeyPair
import java.util.Base64
import java.util.concurrent.TimeUnit

class SshManager {

    private var client: SshClient? = null
    private var session: ClientSession? = null
    private var shellChannel: ChannelShell? = null

    suspend fun connect(config: ConnectionConfig) = withContext(Dispatchers.IO) {
        disconnect()

        val sshClient = SshClient.setUpDefaultClient()
        sshClient.start()
        client = sshClient

        val keyPair = loadKeyPair(config.privateKey)

        val clientSession = sshClient.connect(config.user, config.ip, 22)
            .verify(10, TimeUnit.SECONDS)
            .session

        clientSession.addPublicKeyIdentity(keyPair)
        clientSession.auth().verify(10, TimeUnit.SECONDS)
        session = clientSession
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
                title = parts.getOrElse(1) { "" }.ifBlank { parts.getOrElse(2) { "shell" } },
                command = parts.getOrElse(2) { "" }
            )
        }
    }

    suspend fun openShell(
        tmuxPath: String,
        sessionName: String,
        windowIndex: Int,
        cols: Int,
        rows: Int
    ): Pair<InputStream, OutputStream> = withContext(Dispatchers.IO) {
        val currentSession = session ?: throw IllegalStateException("Not connected")

        val channel = currentSession.createShellChannel()
        channel.setPtyColumns(cols)
        channel.setPtyLines(rows)
        channel.setPtyType("xterm-256color")

        channel.open().verify(10, TimeUnit.SECONDS)
        shellChannel = channel

        // Attach to the tmux session window
        val attachCmd = "$tmuxPath attach -t '${sessionName}:${windowIndex}'\n"
        channel.invertedIn.write(attachCmd.toByteArray())
        channel.invertedIn.flush()

        Pair(channel.invertedOut, channel.invertedIn)
    }

    fun resizeShell(cols: Int, rows: Int) {
        shellChannel?.let { channel ->
            channel.sendWindowChange(cols, rows)
        }
    }

    private suspend fun executeCommand(command: String): String = withContext(Dispatchers.IO) {
        val currentSession = session ?: throw IllegalStateException("Not connected")
        val channel = currentSession.createExecChannel(command)
        channel.open().verify(10, TimeUnit.SECONDS)

        val output = channel.invertedOut.bufferedReader().readText()
        channel.close()
        output
    }

    private fun loadKeyPair(base64Key: String): KeyPair {
        val keyBytes = Base64.getDecoder().decode(base64Key)
        val keyStream = ByteArrayInputStream(keyBytes)
        val loader = SecurityUtils.getKeyPairResourceParser()
        val keyPairs = loader.loadKeyPairs(null, null, null, keyStream)
        return keyPairs.first()
    }

    fun disconnect() {
        shellChannel?.close()
        shellChannel = null
        session?.close()
        session = null
        client?.stop()
        client = null
    }

    val isConnected: Boolean
        get() = session?.isOpen == true
}
