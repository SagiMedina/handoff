package com.handoff.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.handoff.app.BuildConfig
import com.handoff.app.HandoffApp
import com.handoff.app.MainActivity
import com.handoff.app.R
import com.handoff.app.data.ConfigStore
import com.handoff.app.data.NotificationPoster
import com.handoff.app.data.NotificationSubscriber
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Foreground service that keeps the Handoff process alive while the user is connected to
 * their Mac. Without this, Android will kill the process when the Activity backgrounds,
 * taking down the SSH reader thread, tsnet tunnel, and terminal emulator state — which
 * is why the "Retry" button used to fail after the app had been in the background.
 *
 * The service itself doesn't own the connection objects; those live in [HandoffApp] so
 * screens can access them without waiting for a binding. The service's only job is to
 * own the persistent notification and coordinate clean shutdown on explicit disconnect.
 */
class HandoffConnectionService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var subscriber: NotificationSubscriber? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                if (BuildConfig.DEBUG) Log.d(TAG, "ACTION_DISCONNECT")
                teardownAndStop()
                return START_NOT_STICKY
            }
            else -> enterForeground()
        }
        return START_STICKY
    }

    private fun enterForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // specialUse: the app's core flow is "stay connected to your Mac while you
            // switch apps", which has no daily cap — dataSync gets killed after a
            // cumulative 6h/day on Android 14+. connectedDevice would fit semantically
            // but requires a companion Bluetooth/WiFi/NFC/USB permission we don't use.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        startSubscriberIfPaired()
    }

    /**
     * Idempotent — start the long-lived notification subscriber once a paired
     * config exists. The subscriber waits for tsnet to be CONNECTED before
     * making its own SSH connection, so it's safe to start before the user
     * has finished the Tailscale auth flow.
     */
    private fun startSubscriberIfPaired() {
        if (subscriber != null) return
        val app = applicationContext as HandoffApp
        val configStore = ConfigStore(applicationContext)
        val sub = NotificationSubscriber(
            appContext = applicationContext,
            tailscaleManager = app.tailscaleManager,
            configStore = configStore,
        )
        sub.start()
        subscriber = sub
    }

    private fun buildNotification(): Notification {
        val openPi = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val disconnectPi = PendingIntent.getService(
            this,
            1,
            Intent(this, HandoffConnectionService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Handoff")
            .setContentText("Connected to Mac")
            .setContentIntent(openPi)
            // On Android 14+ a connectedDevice notification is user-dismissable by swipe.
            // Route the dismissal through ACTION_DISCONNECT so we don't leave a zombie
            // connection running without a visible notification.
            .setDeleteIntent(disconnectPi)
            .addAction(0, "Disconnect", disconnectPi)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setShowWhen(false)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Handoff connection",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while Handoff is connected to your Mac"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
        if (nm.getNotificationChannel(NotificationPoster.CHANNEL_ID_EVENTS) == null) {
            // Separate channel from the persistent connection notification:
            // the user may want sound + heads-up for "Claude is waiting" but
            // a silent service notification — Android lets them tune those
            // independently.
            val channel = NotificationChannel(
                NotificationPoster.CHANNEL_ID_EVENTS,
                "Claude activity",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Pushes when Claude on your Mac is waiting for input or finishes."
                enableLights(true)
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun teardownAndStop() {
        val app = applicationContext as HandoffApp
        runCatching { subscriber?.stop() }
        subscriber = null
        scope.launch {
            runCatching { app.terminalHolder.disconnect() }
            runCatching { app.sshManager.disconnect() }
            runCatching { app.tailscaleManager.stopProxy() }
            runCatching { app.tailscaleManager.stop() }
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }

    companion object {
        private const val TAG = "HandoffService"
        const val CHANNEL_ID = "handoff_connection"
        const val NOTIFICATION_ID = 1
        const val ACTION_DISCONNECT = "com.handoff.app.action.DISCONNECT"

        /** Start the foreground service. Idempotent — safe to call whenever we want to be alive. */
        fun start(context: Context) {
            val intent = Intent(context, HandoffConnectionService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        /** Request the service to tear down the connection and stop itself. */
        fun disconnect(context: Context) {
            val intent = Intent(context, HandoffConnectionService::class.java)
                .setAction(ACTION_DISCONNECT)
            context.startService(intent)
        }
    }
}
