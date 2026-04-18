package com.handoff.app.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "handoff")

class ConfigStore(private val context: Context) {

    companion object {
        private val KEY_IP = stringPreferencesKey("ip")
        private val KEY_USER = stringPreferencesKey("user")
        private val KEY_PRIVATE_KEY = stringPreferencesKey("private_key")
        private val KEY_TMUX_PATH = stringPreferencesKey("tmux_path")
        private val KEY_PROTOCOL_VERSION = intPreferencesKey("protocol_version")
        private val KEY_DEVICE_NAME = stringPreferencesKey("device_name")
        private val KEY_NONCE = stringPreferencesKey("nonce")
        private val KEY_TERMINAL_FONT_SIZE = intPreferencesKey("terminal_font_size")
        // Pinned tabs, stored as "sessionName\u0000windowTitle". Title (not index) because
        // tmux indices can shift when tabs are killed, but the user recognizes a tab by its
        // title. NUL separator avoids collisions with user-chosen session/title characters.
        private val KEY_PINNED_WINDOWS = stringSetPreferencesKey("pinned_windows")
        const val PIN_SEP = "\u0000"

        const val DEFAULT_TERMINAL_FONT_SIZE = 24
        const val MIN_TERMINAL_FONT_SIZE = 12
        const val MAX_TERMINAL_FONT_SIZE = 40
    }

    val terminalFontSize: Flow<Int> = context.dataStore.data.map { prefs ->
        prefs[KEY_TERMINAL_FONT_SIZE] ?: DEFAULT_TERMINAL_FONT_SIZE
    }

    suspend fun setTerminalFontSize(size: Int) {
        val clamped = size.coerceIn(MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE)
        context.dataStore.edit { it[KEY_TERMINAL_FONT_SIZE] = clamped }
    }

    val pinnedWindows: Flow<Set<String>> = context.dataStore.data.map { prefs ->
        prefs[KEY_PINNED_WINDOWS] ?: emptySet()
    }

    suspend fun togglePinnedWindow(session: String, title: String) {
        val key = "$session$PIN_SEP$title"
        context.dataStore.edit { prefs ->
            val current = prefs[KEY_PINNED_WINDOWS] ?: emptySet()
            prefs[KEY_PINNED_WINDOWS] =
                if (key in current) current - key else current + key
        }
    }

    suspend fun save(config: ConnectionConfig) {
        context.dataStore.edit { prefs ->
            prefs[KEY_IP] = config.ip
            prefs[KEY_USER] = config.user
            prefs[KEY_PRIVATE_KEY] = config.privateKey
            prefs[KEY_TMUX_PATH] = config.tmuxPath
            prefs[KEY_PROTOCOL_VERSION] = config.protocolVersion
            prefs[KEY_DEVICE_NAME] = config.deviceName
            prefs[KEY_NONCE] = config.nonce
        }
    }

    suspend fun load(): ConnectionConfig? {
        val prefs = context.dataStore.data.first()
        val ip = prefs[KEY_IP] ?: return null
        val user = prefs[KEY_USER] ?: return null
        val key = prefs[KEY_PRIVATE_KEY] ?: return null
        val tmux = prefs[KEY_TMUX_PATH] ?: return null
        return ConnectionConfig(
            ip = ip,
            user = user,
            privateKey = key,
            tmuxPath = tmux,
            protocolVersion = prefs[KEY_PROTOCOL_VERSION] ?: 1,
            deviceName = prefs[KEY_DEVICE_NAME] ?: "",
            nonce = prefs[KEY_NONCE] ?: ""
        )
    }

    suspend fun clear() {
        context.dataStore.edit { it.clear() }
    }

    fun isPaired() = context.dataStore.data.map { prefs ->
        prefs[KEY_IP] != null
    }
}
