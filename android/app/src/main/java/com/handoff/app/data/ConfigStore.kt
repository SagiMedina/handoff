package com.handoff.app.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "handoff")

class ConfigStore(private val context: Context) {

    companion object {
        private val KEY_IP = stringPreferencesKey("ip")
        private val KEY_USER = stringPreferencesKey("user")
        private val KEY_PRIVATE_KEY = stringPreferencesKey("private_key")
        private val KEY_TMUX_PATH = stringPreferencesKey("tmux_path")
    }

    suspend fun save(config: ConnectionConfig) {
        context.dataStore.edit { prefs ->
            prefs[KEY_IP] = config.ip
            prefs[KEY_USER] = config.user
            prefs[KEY_PRIVATE_KEY] = config.privateKey
            prefs[KEY_TMUX_PATH] = config.tmuxPath
        }
    }

    suspend fun load(): ConnectionConfig? {
        val prefs = context.dataStore.data.first()
        val ip = prefs[KEY_IP] ?: return null
        val user = prefs[KEY_USER] ?: return null
        val key = prefs[KEY_PRIVATE_KEY] ?: return null
        val tmux = prefs[KEY_TMUX_PATH] ?: return null
        return ConnectionConfig(ip, user, key, tmux)
    }

    suspend fun clear() {
        context.dataStore.edit { it.clear() }
    }

    fun isPaired() = context.dataStore.data.map { prefs ->
        prefs[KEY_IP] != null
    }
}
