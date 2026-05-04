package com.handoff.app.data

import android.content.Context
import android.util.Log
import com.handoff.app.BuildConfig
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.security.Security
import java.util.Base64
import java.util.Properties

private const val TAG = "HandoffSubscriber"

/**
 * Long-lived consumer of `handoff gate subscribe` over SSH. Drives the push-
 * notification side of Handoff.
 *
 * Why it owns its own [Session] and doesn't reuse [SshManager]:
 *  - [SshManager.connect] calls [SshManager.disconnect] first; any
 *    re-connect from the terminal flow would also kill the subscription.
 *  - The terminal session churns (open/close on every tab switch); the
 *    subscription needs to outlive that churn for the entire foreground-
 *    service lifetime.
 *  - JSch supports multiple Sessions on one process, so the cost is one
 *    extra TCP connection over Tailscale per device.
 *
 * Lifecycle: started by [HandoffConnectionService.enterForeground] when a
 * paired config exists; stopped by [HandoffConnectionService.teardownAndStop].
 *
 * Failure handling:
 *  - Any exception during connect/read schedules a reconnect with exponential
 *    backoff (1s → 30s, capped). Backoff resets the moment the first event
 *    arrives, so a flaky network doesn't stretch retries forever.
 *  - SIGPIPE-equivalent (the gate's stream helper exits cleanly when the
 *    phone closes the channel) just shows up here as EOF on the reader and
 *    triggers reconnect.
 */
class NotificationSubscriber(
    private val appContext: Context,
    private val tailscaleManager: TailscaleManager,
    private val configStore: ConfigStore,
) {
    private val poster = NotificationPoster(appContext)
    private val cursorStore = NotificationCursorStore(appContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var loopJob: Job? = null
    @Volatile private var session: Session? = null
    @Volatile private var channel: ChannelExec? = null

    private val backoffSchedule = listOf(1_000L, 2_000L, 4_000L, 8_000L, 15_000L, 30_000L)

    /** Idempotent — calling twice is a no-op. */
    fun start() {
        if (loopJob?.isActive == true) return
        // Clear any leftovers from a prior run before we start replaying;
        // the stream's cursor logic owns state from now on.
        poster.cancelAllEvents()
        loopJob = scope.launch { runLoop() }
    }

    fun stop() {
        loopJob?.cancel()
        loopJob = null
        runCatching { channel?.disconnect() }
        runCatching { session?.disconnect() }
        channel = null
        session = null
    }

    private suspend fun runLoop() {
        var backoffIdx = 0
        while (scope.isActive) {
            try {
                val delivered = connectAndStream()
                // Stream ended cleanly (EOF). Treat as a network blip and
                // reconnect — but if we received any events this round, give
                // the next backoff slot a clean slate.
                if (delivered > 0) backoffIdx = 0
            } catch (t: Throwable) {
                if (BuildConfig.DEBUG) Log.w(TAG, "stream failed: ${t.javaClass.simpleName}: ${t.message}")
            } finally {
                runCatching { channel?.disconnect() }
                runCatching { session?.disconnect() }
                channel = null
                session = null
            }
            if (!scope.isActive) return
            val sleep = backoffSchedule[backoffIdx.coerceAtMost(backoffSchedule.lastIndex)]
            backoffIdx = (backoffIdx + 1).coerceAtMost(backoffSchedule.lastIndex)
            delay(sleep)
        }
    }

    /** Returns the number of events delivered this round (post or suppress). */
    private suspend fun connectAndStream(): Int = withContext(Dispatchers.IO) {
        val config = configStore.load() ?: return@withContext 0
        // v2-only: gate subscribe doesn't exist on legacy v1 setups.
        if (config.protocolVersion < 2) return@withContext 0

        // Wait for tsnet to be CONNECTED and a proxy to exist before we even
        // try. The terminal flow normally brings up the proxy; if it hasn't
        // (user paired but never opened a terminal), bring up our own.
        waitUntilTailscaleReady()
        var port = tailscaleManager.getProxyPort()
        if (port == 0) {
            port = tailscaleManager.startProxy(config.ip, 22)
            if (BuildConfig.DEBUG) Log.d(TAG, "started proxy on port $port")
        }

        ensureBouncyCastle()
        val jsch = JSch()
        val keyBytes = Base64.getDecoder().decode(config.privateKey)
        jsch.addIdentity("handoff-notify", keyBytes, null, null)

        val s = jsch.getSession(config.user, "127.0.0.1", port)
        s.setConfig(Properties().apply { setProperty("StrictHostKeyChecking", "no") })
        // Fairly aggressive keep-alive: gate streams a heartbeat every 25s,
        // so 15s × 3 means we detect a dead tunnel within ~45s and reconnect.
        s.setServerAliveInterval(15_000)
        s.setServerAliveCountMax(3)
        s.connect(15_000)
        session = s

        val sinceCursor = cursorStore.lastSeenId
        val ch = s.openChannel("exec") as ChannelExec
        ch.setCommand("subscribe since=$sinceCursor")
        // Don't feed stdin to the gate — the subscribe protocol only sends.
        ch.inputStream = null
        val input = ch.inputStream
        ch.connect(10_000)
        channel = ch

        if (BuildConfig.DEBUG) Log.d(TAG, "connected; subscribe since=$sinceCursor")

        var delivered = 0
        runInterruptible {
            BufferedReader(InputStreamReader(input, Charsets.UTF_8)).useLines { lines ->
                for (line in lines) {
                    val handled = handleLine(line, sinceCursor)
                    if (handled) delivered++
                }
            }
        }
        delivered
    }

    /**
     * Returns true when this line counted as a delivered event (i.e. should
     * count against the "got something this round" check that resets backoff).
     * `ping` and `ready` lines return false.
     */
    private fun handleLine(rawLine: String, sinceCursor: Long): Boolean {
        val line = rawLine.trim()
        if (line.isEmpty()) return false

        val obj = try {
            JSONObject(line)
        } catch (_: Throwable) {
            return false
        }

        when (obj.optString("type")) {
            "ping" -> return false
            "ready" -> {
                val maxId = obj.optLong("last_id", 0L)
                // If our cursor is ahead of the Mac's max id, the log was
                // rotated below us. Snap forward so we don't replay the
                // entire next rotation cycle later.
                if (cursorStore.lastSeenId > maxId && maxId >= 0) {
                    if (BuildConfig.DEBUG) Log.w(
                        TAG, "cursor ${cursorStore.lastSeenId} > max $maxId; snapping forward"
                    )
                    cursorStore.lastSeenId = maxId
                }
                return false
            }
        }

        val event = parseEvent(obj) ?: return false
        if (event.id <= sinceCursor) return false

        try {
            poster.deliver(event)
        } catch (t: Throwable) {
            if (BuildConfig.DEBUG) Log.w(TAG, "deliver failed: ${t.javaClass.simpleName}: ${t.message}")
        }
        // Persist only after we made a decision about this event. If we
        // crashed before this line, the next reconnect will replay it.
        cursorStore.lastSeenId = event.id
        return true
    }

    private fun parseEvent(obj: JSONObject): HandoffEvent? {
        val id = obj.optLong("id", -1L)
        if (id <= 0) return null
        val type = obj.optString("type", "")
        val message = obj.optString("message", "")
        val tmuxSession = obj.optString("tmux_session", "").ifBlank { null }
        val tmuxWindow = if (obj.has("tmux_window")) obj.optInt("tmux_window", -1).takeIf { it >= 0 } else null
        return HandoffEvent(
            id = id,
            type = type,
            title = obj.optString("title", "").ifBlank { null },
            message = message,
            tmuxSession = tmuxSession,
            tmuxWindow = tmuxWindow,
            cwd = obj.optString("cwd", "").ifBlank { null },
            source = obj.optString("source", "").ifBlank { null },
            claudeSessionId = obj.optString("claude_session_id", "").ifBlank { null },
        )
    }

    private suspend fun waitUntilTailscaleReady() {
        // Cheap poll of the StateFlow rather than collect{} — we just want
        // a single edge before proceeding, and the flow never emits more
        // than a handful of times per session.
        while (scope.isActive && tailscaleManager.state.value != TailscaleState.CONNECTED) {
            delay(500)
        }
    }

    private fun ensureBouncyCastle() {
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.insertProviderAt(BouncyCastleProvider(), 1)
        }
    }
}
