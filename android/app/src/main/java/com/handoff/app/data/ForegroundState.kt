package com.handoff.app.data

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Process-wide signals the notification subscriber consults to decide whether
 * to suppress a push for the tab the user is currently viewing.
 *
 * "Currently viewing" is the conjunction of three flows — any one being false
 * is enough to stop suppressing:
 *  - [isForeground]: an Activity is in started state.
 *  - [activeTerminalTab]: TerminalScreen is composed at this (session, window).
 *  - [currentRoute]: the live NavController destination is a `terminal/...`
 *    route. The tab values can lag NavController briefly on tab-to-tab moves,
 *    so the route check is the authoritative answer to "is the user actually
 *    looking at terminal output right now?"
 *
 * Updated from:
 *  - HandoffApp registers an ActivityLifecycleCallbacks tracker for
 *    [isForeground].
 *  - MainActivity adds an OnDestinationChangedListener for [currentRoute].
 *  - TerminalScreen sets/clears [activeTerminalTab] in a DisposableEffect.
 */
object ForegroundState {
    val isForeground = MutableStateFlow(false)
    val activeTerminalTab = MutableStateFlow<Pair<String, Int>?>(null)
    val currentRoute = MutableStateFlow<String?>(null)

    /**
     * True when the user is actively viewing the given tab in a foregrounded
     * Handoff app — the suppression rule used by [NotificationPoster].
     */
    fun isViewing(session: String, window: Int): Boolean {
        if (!isForeground.value) return false
        if (currentRoute.value?.startsWith("terminal/") != true) return false
        return activeTerminalTab.value == (session to window)
    }
}
