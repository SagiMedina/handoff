package com.handoff.app.data

data class ConnectionConfig(
    val ip: String,
    val user: String,
    val privateKey: String, // base64 encoded
    val tmuxPath: String
)

data class TmuxSession(
    val name: String,
    val windowCount: Int,
    val windows: List<TmuxWindow> = emptyList()
)

data class TmuxWindow(
    val index: Int,
    val title: String,
    val command: String,
    val cwd: String = ""
)
