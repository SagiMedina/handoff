package com.handoff.app.data

import android.content.Context
import android.content.SharedPreferences

/**
 * Persists the highest event id the phone has *consumed* (posted or
 * suppressed) from the Handoff event stream. The subscriber resumes with
 * `subscribe since=<lastSeenId>` so events queued while the phone was offline
 * are replayed on reconnect.
 *
 * SharedPreferences is the right tool here: a single Long, written rarely
 * (once per delivered event), survives process death and reboots, no schema.
 */
class NotificationCursorStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var lastSeenId: Long
        get() = prefs.getLong(KEY_LAST_SEEN_ID, 0L)
        set(value) {
            // commit() is synchronous; we want the cursor durable before we
            // ack to ourselves that the event was delivered. Throughput is
            // fine — events are human-paced.
            prefs.edit().putLong(KEY_LAST_SEEN_ID, value).commit()
        }

    fun reset() {
        prefs.edit().remove(KEY_LAST_SEEN_ID).commit()
    }

    companion object {
        private const val PREFS_NAME = "handoff_notify"
        private const val KEY_LAST_SEEN_ID = "last_seen_id"
    }
}
