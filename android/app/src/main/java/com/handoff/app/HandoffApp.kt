package com.handoff.app

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.handoff.app.data.ForegroundState
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.data.TerminalSessionHolder

class HandoffApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        appFilesDir = filesDir.absolutePath
        registerActivityLifecycleCallbacks(ForegroundTracker())
    }

    // Process-scoped holders. Survive Activity teardown so the SSH reader thread,
    // tmux emulator state, and tsnet tunnel stay alive when the app backgrounds.
    // HandoffConnectionService keeps the process from being killed while these are in use.
    val sshManager: SshManager by lazy { SshManager() }
    val tailscaleManager: TailscaleManager by lazy { TailscaleManager(appFilesDir) }
    val terminalHolder: TerminalSessionHolder by lazy { TerminalSessionHolder(applicationContext) }

    /**
     * Tracks whether any Activity is in the started state and pipes the
     * answer into [ForegroundState.isForeground]. The notification subscriber
     * reads that flag to decide whether to suppress a push for the active tab.
     *
     * Counting started-vs-stopped (not resumed/paused) is the right signal:
     * the user's "I can see the screen" state, which a transient dialog
     * doesn't change.
     */
    private class ForegroundTracker : ActivityLifecycleCallbacks {
        private var started = 0
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityStarted(activity: Activity) {
            started++
            if (started == 1) ForegroundState.isForeground.value = true
        }
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {
            started = (started - 1).coerceAtLeast(0)
            if (started == 0) ForegroundState.isForeground.value = false
        }
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    companion object {
        lateinit var instance: HandoffApp
            private set

        var appFilesDir: String = ""
            private set
    }
}
