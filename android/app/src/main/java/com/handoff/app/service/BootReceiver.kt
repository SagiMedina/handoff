package com.handoff.app.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.handoff.app.BuildConfig
import com.handoff.app.data.ConfigStore
import kotlinx.coroutines.runBlocking

/**
 * Wakes the foreground service back up after a reboot or APK upgrade.
 *
 * Without this, the user has to manually reopen the app for the
 * notification subscriber to start — which defeats the "always notified
 * while paired" promise. With this, as soon as the user unlocks for the
 * first time after boot, the receiver fires, the service starts, and the
 * subscriber resumes from its persisted cursor.
 *
 * `MY_PACKAGE_REPLACED` covers in-place app updates (e.g. Play Store
 * autoupdate) where the foreground service was killed by the install.
 *
 * The receiver is intentionally cheap — a single `runBlocking` to load
 * the paired config, then a service start. If unpaired, it does nothing
 * so unpaired users never see a "Handoff connected" notification on boot.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> Unit
            else -> return
        }

        val paired = runCatching {
            runBlocking { ConfigStore(context.applicationContext).load() != null }
        }.getOrDefault(false)

        if (!paired) {
            if (BuildConfig.DEBUG) Log.d(TAG, "boot/replace: not paired, skipping")
            return
        }

        if (BuildConfig.DEBUG) Log.d(TAG, "boot/replace: starting service")
        HandoffConnectionService.start(context.applicationContext)
    }

    companion object {
        private const val TAG = "HandoffBootReceiver"
    }
}
