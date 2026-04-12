package com.handoff.app.data

import android.util.Log
import gobridge.Gobridge
import gobridge.StatusCallback
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

enum class TailscaleState {
    STOPPED, STARTING, NEEDS_AUTH, CONNECTED, ERROR
}

class TailscaleManager(private val stateDir: String) {

    private val _state = MutableStateFlow(TailscaleState.STOPPED)
    val state: StateFlow<TailscaleState> = _state

    private val _authUrl = MutableStateFlow<String?>(null)
    val authUrl: StateFlow<String?> = _authUrl

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error

    private var proxyPort: Int = 0

    suspend fun start(hostname: String = "handoff-android") {
        if (_state.value == TailscaleState.CONNECTED) return

        _state.value = TailscaleState.STARTING
        _error.value = null

        suspendCancellableCoroutine { cont ->
            val tsDir = "$stateDir/tailscale"
            java.io.File(tsDir).mkdirs()

            Gobridge.start(tsDir, hostname, object : StatusCallback {
                override fun onAuthURL(url: String) {
                    Log.d("Handoff", "Tailscale auth URL: $url")
                    _authUrl.value = url
                    _state.value = TailscaleState.NEEDS_AUTH
                }

                override fun onConnected() {
                    Log.d("Handoff", "Tailscale connected")
                    _state.value = TailscaleState.CONNECTED
                    _authUrl.value = null
                    if (cont.isActive) cont.resume(Unit)
                }

                override fun onError(err: String) {
                    Log.e("Handoff", "Tailscale error: $err")
                    _state.value = TailscaleState.ERROR
                    _error.value = err
                    if (cont.isActive) cont.resumeWithException(
                        RuntimeException("Tailscale: $err")
                    )
                }
            })
        }
    }

    fun startProxy(targetIp: String, targetPort: Int = 22): Int {
        proxyPort = Gobridge.startProxy(targetIp, targetPort.toLong()).toInt()
        Log.d("Handoff", "Tailscale proxy: $targetIp:$targetPort -> localhost:$proxyPort")
        return proxyPort
    }

    fun getProxyPort(): Int = proxyPort

    fun stopProxy() {
        Gobridge.stopProxy()
        proxyPort = 0
    }

    fun stop() {
        Gobridge.stop()
        _state.value = TailscaleState.STOPPED
        proxyPort = 0
    }

    fun resetState() {
        stop()
        java.io.File("$stateDir/tailscale").deleteRecursively()
    }

    val isConnected: Boolean
        get() = _state.value == TailscaleState.CONNECTED
}
