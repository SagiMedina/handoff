package com.handoff.app

import android.app.Application

class HandoffApp : Application() {
    override fun onCreate() {
        super.onCreate()
        appFilesDir = filesDir.absolutePath
    }

    companion object {
        var appFilesDir: String = ""
            private set
    }
}
