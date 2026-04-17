package com.handoff.app.data

/**
 * Maps raw exceptions to user-friendly error messages with actionable hints.
 */
fun friendlyConnectionError(e: Exception): String {
    val msg = (e.message ?: "").lowercase()
    val cause = (e.cause?.message ?: "").lowercase()

    return when {
        // Tailscale-level failures
        msg.startsWith("tailscale:") ->
            "Tailscale couldn't connect.\nMake sure Tailscale is running on your Mac."

        // SSH auth failures
        "auth fail" in msg || "auth cancel" in msg || "publickey" in msg ->
            "Authentication failed.\nTry re-pairing from your Mac with `handoff pair`."

        // Connection refused — SSH not enabled or not listening
        "connection refused" in msg || "connection refused" in cause ->
            "Mac refused the connection.\nMake sure Remote Login (SSH) is enabled in\nSystem Settings > General > Sharing."

        // Timeout — Mac asleep, network slow, or Tailscale not connected
        "timeout" in msg || "timed out" in msg || "sockettimeout" in msg ->
            "Connection timed out.\nMake sure your Mac is awake and both devices are on Tailscale."

        // Network unreachable
        "no route" in msg || "unreachable" in msg || "unknownhost" in msg ||
        "no route" in cause || "unreachable" in cause ->
            "Can't reach your Mac.\nCheck that both devices are connected to Tailscale."

        // SSH session dropped
        "not connected" in msg || "session is down" in msg || "channel is not opened" in msg ->
            "Disconnected from Mac.\nTap Retry to reconnect."

        // Proxy / Tailscale networking
        "proxy" in msg || "dial" in msg ->
            "Network tunnel failed.\nMake sure Tailscale is running on both devices."

        // Catch-all
        else ->
            "Connection error.\nMake sure your Mac is awake and Tailscale is running."
    }
}

fun friendlyTailscaleError(rawError: String?): String {
    if (rawError == null) return "Tailscale connection failed.\nTap Retry to try again."
    val msg = rawError.lowercase()
    return when {
        "auth" in msg || "login" in msg || "expired" in msg ->
            "Tailscale login expired.\nTap Reset & Retry to sign in again."
        "timeout" in msg || "timed out" in msg ->
            "Tailscale is taking too long to connect.\nCheck your internet connection and try again."
        "dns" in msg || "resolve" in msg ->
            "Can't reach Tailscale servers.\nCheck your internet connection."
        else ->
            "Tailscale couldn't connect.\nCheck your internet connection and try again."
    }
}

fun friendlyActionError(action: String, e: Exception): String {
    if (e is GateException) return friendlyGateError(e.gateError)
    val msg = (e.message ?: "").lowercase()
    return when {
        "not connected" in msg || "session is down" in msg ->
            "Lost connection to Mac — tap Refresh to reconnect."
        else ->
            "Couldn't $action — tap Refresh to try again."
    }
}

fun friendlyGateError(error: String): String = when (error) {
    "error:denied" -> "This session is not available on this device."
    "error:read_only" -> "This device has read-only access."
    "error:soft_expired" -> "Your access has expired.\nRequest a renewal from the Mac owner."
    "error:pending" -> "Pairing is not yet complete.\nWait for verification on your Mac."
    "error:not_found" -> "This device is not registered.\nRe-pair from your Mac with `handoff pair`."
    "error:unknown_command" -> "Protocol error.\nYour Mac may need a Handoff update."
    else -> "Access denied: ${error.removePrefix("error:")}"
}
