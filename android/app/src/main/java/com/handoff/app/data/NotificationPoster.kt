package com.handoff.app.data

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.handoff.app.MainActivity
import com.handoff.app.R

/**
 * One inbound event from the Mac.
 *
 * Field naming mirrors the JSON schema written by `handoff notify` so the
 * reader stays trivial. `tmuxSession`/`tmuxWindow` are nullable because
 * Claude Code can run outside tmux — those events still deliver, just
 * without a tab to deep-link to.
 */
data class HandoffEvent(
    val id: Long,
    val type: String,
    val title: String?,
    val message: String,
    val tmuxSession: String?,
    val tmuxWindow: Int?,
    val cwd: String?,
    val source: String?,
    val claudeSessionId: String?,
)

/**
 * Posts inbound Handoff events as Android notifications.
 *
 * Per-tab dedupe is achieved by deriving the notification id from the tab
 * key — re-posting with the same id replaces the existing notification in
 * place, so a Stop event for a tab updates its earlier "Claude is waiting"
 * notification rather than stacking. Events without a tab use a separate
 * notification id space so they never collide with tab notifications.
 *
 * Suppression is delegated to [ForegroundState]: if the user is actively
 * viewing the tab, we don't post — but we *do* cancel any stale notification
 * for that tab and consider the event "delivered" (so the caller advances
 * the cursor past it).
 */
class NotificationPoster(private val context: Context) {

    /**
     * Returns true if the event was posted (or intentionally dropped).
     * Returning at all means "advance the cursor past this id".
     */
    fun deliver(event: HandoffEvent) {
        val nm = NotificationManagerCompat.from(context)
        val notifId = notificationIdFor(event)

        if (event.tmuxSession != null && event.tmuxWindow != null
            && ForegroundState.isViewing(event.tmuxSession, event.tmuxWindow)) {
            // Currently viewing this tab — drop the post and clear any
            // stale notification we left behind from a prior state.
            nm.cancel(notifId)
            return
        }

        val title = event.title ?: defaultTitle(event)
        // Tab indicator goes in subText so the user always knows which tab the
        // event came from, even when the source (e.g. the Claude Code plugin)
        // sets a generic title like "Claude finished".
        val tabSubText = tabSubText(event)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID_EVENTS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(event.message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(event.message))
            .setAutoCancel(true)
            .setOngoing(false)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(deepLinkIntent(event, notifId))
        if (tabSubText != null) builder.setSubText(tabSubText)

        try {
            nm.notify(notifId, builder.build())
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS denied on Android 13+. The cursor still
            // advances; the user gets nothing until they grant permission.
        }
    }

    /**
     * Cancel any notification belonging to a tab the user just opened. Called
     * from TerminalScreen on enter so the badge clears immediately even if
     * the suppression rule didn't catch the moment of post.
     */
    fun cancelForTab(session: String, window: Int) {
        NotificationManagerCompat.from(context)
            .cancel(tabIdFor(session, window))
    }

    /**
     * Cancel every Handoff event notification (e.g. on subscriber start so
     * stale notifications from a previous run don't linger past their
     * usefulness).
     */
    fun cancelAllEvents() {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        val active = nm.activeNotifications ?: return
        for (sn in active) {
            if (sn.notification?.channelId == CHANNEL_ID_EVENTS) {
                nm.cancel(sn.tag, sn.id)
            }
        }
    }

    private fun defaultTitle(event: HandoffEvent): String = when (event.type) {
        "stop"   -> "Claude finished"
        "notify" -> "Claude is waiting"
        else     -> "Handoff"
    }

    /**
     * Compact "where did this come from?" indicator for the small-text header.
     *
     * Priority is the cwd's last folder name (what users actually recognize —
     * "handoff" is meaningful; "main · #1" is not). Falls back to the tmux
     * tab coordinates when no usable cwd is present, and returns null when
     * neither — those events display without a subtext rather than misleading
     * the user with a phantom location.
     */
    private fun tabSubText(event: HandoffEvent): String? {
        folderName(event.cwd)?.let { return it }
        val s = event.tmuxSession ?: return null
        val w = event.tmuxWindow ?: return null
        return "$s · #$w"
    }

    private fun folderName(cwd: String?): String? {
        if (cwd.isNullOrBlank()) return null
        val trimmed = cwd.trimEnd('/')
        if (trimmed.isEmpty()) return null  // root "/"
        val name = trimmed.substringAfterLast('/')
        return name.ifBlank { null }
    }

    private fun deepLinkIntent(event: HandoffEvent, tabId: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_OPEN_TAB
            // Distinct PendingIntent per id (tab); without this, Android
            // recycles a single PendingIntent and reuses the first event's
            // extras for every notification on the channel.
            data = android.net.Uri.parse(
                "handoff://event/${event.id}/${event.tmuxSession ?: ""}/${event.tmuxWindow ?: -1}"
            )
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            event.tmuxSession?.let { putExtra(MainActivity.EXTRA_DEEPLINK_SESSION, it) }
            event.tmuxWindow?.let { putExtra(MainActivity.EXTRA_DEEPLINK_WINDOW, it) }
        }
        return PendingIntent.getActivity(
            context,
            tabId,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    companion object {
        const val CHANNEL_ID_EVENTS = "handoff_events"

        /**
         * Stable per-tab notification id. With a handful of tabs in active
         * use, [String.hashCode] collisions are vanishingly rare, and any
         * collision just causes one tab to replace another's notification
         * (still better than stacking). Range is forced into the lower half
         * (bit 30 clear) so it can't collide with the no-tab id space.
         */
        fun tabIdFor(session: String, window: Int): Int =
            "$session:$window".hashCode() and 0x3FFFFFFF

        /**
         * Notification id for one event. Tab events dedupe per tab; no-tab
         * events get a unique id derived from the event id (high-bit set so
         * they can't collide with tab ids).
         */
        fun notificationIdFor(event: HandoffEvent): Int {
            val s = event.tmuxSession
            val w = event.tmuxWindow
            if (s != null && w != null) return tabIdFor(s, w)
            return (event.id.toInt() and 0x3FFFFFFF) or 0x40000000
        }
    }
}
