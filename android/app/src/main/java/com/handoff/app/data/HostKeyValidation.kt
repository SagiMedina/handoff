package com.handoff.app.data

import android.util.Base64
import java.security.MessageDigest

data class PendingTrustRequest(
    val host: String,
    val type: String,
    val fingerprint: String,
    val keyBytes: ByteArray,
)

class HostKeyUnknownException(val request: PendingTrustRequest) :
    Exception("Unknown SSH host key for ${request.host}")

class HostKeyMismatchException(
    val host: String,
    val type: String,
    val expectedFingerprint: String,
    val actualFingerprint: String,
) : Exception("SSH host key changed for $host")

object HostKeyFingerprint {
    fun sha256(keyBytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(keyBytes)
        val encoded = Base64.encodeToString(digest, Base64.NO_WRAP).trimEnd('=')
        return "SHA256:$encoded"
    }
}
