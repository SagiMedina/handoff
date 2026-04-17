package com.handoff.app.data

import android.content.Context
import android.content.SharedPreferences

/**
 * Manages the biometric app lock preference.
 * The biometric check is a UI gate (BiometricGateScreen) — not crypto-bound.
 * The SSH key itself remains in the regular DataStore.
 */
class BiometricKeyStore(private val context: Context) {

    companion object {
        private const val PREFS_NAME = "handoff_biometric"
        private const val PREF_BIOMETRIC_ENABLED = "biometric_enabled"
    }

    private val prefs: SharedPreferences
        get() = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    val isBiometricEnabled: Boolean
        get() = prefs.getBoolean(PREF_BIOMETRIC_ENABLED, false)

    // hasStoredKey is checked by MainActivity to decide whether to show biometric gate
    // Since we just use a preference flag, this is equivalent to isBiometricEnabled
    val hasStoredKey: Boolean
        get() = isBiometricEnabled

    fun setEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(PREF_BIOMETRIC_ENABLED, enabled).apply()
    }

    fun saveKey(privateKeyBase64: String, requireBiometric: Boolean) {
        setEnabled(requireBiometric)
    }

    fun deleteKey() {
        prefs.edit().clear().apply()
    }
}
