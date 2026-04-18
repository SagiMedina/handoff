package com.handoff.app

import android.app.Application
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.data.TerminalSessionHolder

class HandoffApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        appFilesDir = filesDir.absolutePath
    }

    // Process-scoped holders. Survive Activity teardown so the SSH reader thread,
    // tmux emulator state, and tsnet tunnel stay alive when the app backgrounds.
    // HandoffConnectionService keeps the process from being killed while these are in use.
    val sshManager: SshManager by lazy { SshManager() }
    val tailscaleManager: TailscaleManager by lazy { TailscaleManager(appFilesDir) }
    val terminalHolder: TerminalSessionHolder by lazy { TerminalSessionHolder(applicationContext) }

    companion object {
        lateinit var instance: HandoffApp
            private set

        var appFilesDir: String = ""
            private set
    }
}
