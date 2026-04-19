package com.handoff.app.data

import android.content.Context
import android.util.Base64

data class TrustedHostKey(
    val host: String,
    val type: String,
    val keyBytes: ByteArray,
) {
    val fingerprint: String
        get() = HostKeyFingerprint.sha256(keyBytes)
}

class HostKeyStore(context: Context) {
    private val prefs = context.getSharedPreferences("handoff_host_keys", Context.MODE_PRIVATE)

    fun get(host: String): TrustedHostKey? {
        val raw = prefs.getString(host, null) ?: return null
        val parts = raw.split("|", limit = 2)
        if (parts.size != 2) return null
        val type = parts[0]
        val keyBytes = try {
            Base64.decode(parts[1], Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return null
        }
        return TrustedHostKey(host = host, type = type, keyBytes = keyBytes)
    }

    fun trust(host: String, type: String, keyBytes: ByteArray) {
        val encoded = Base64.encodeToString(keyBytes, Base64.NO_WRAP)
        prefs.edit().putString(host, "$type|$encoded").apply()
    }

    fun forget(host: String) {
        prefs.edit().remove(host).apply()
    }

    fun hasTrust(host: String): Boolean = prefs.contains(host)
}
